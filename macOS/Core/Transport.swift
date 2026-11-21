import CoreFoundation
import Foundation

enum Gateway: String, CaseIterable {
  case campus = "172.17.1.90"
  case wired = "172.31.0.10"
  var page: String { self == .wired ? "/a79.htm" : "/" }
  var title: String { self == .wired ? "有线入口" : "常用入口" }
}

enum GatewayOperation: String {
  case status = "/drcom/chkstatus"
  case page = "/"
  case config = "/eportal/portal/page/loadConfig"
  case login = "/eportal/portal/login"
  case logout = "/eportal/portal/logout"
  case legacy = "/drcom/logout"
  case find = "/eportal/portal/mac/find"
  case unbind = "/eportal/portal/mac/unbind"
  var port: Int { [.page, .status, .legacy].contains(self) ? 80 : 801 }
}

enum PortalError: Error, LocalizedError, Equatable {
  case network(Int)
  case http(Int)
  case response, device, config, credentials, rejected, uncertain, startupNetwork, sessionChanged
  var errorDescription: String? {
    switch self {
    case .network(let code): return "无法连接入口（\(code)）。请检查校园网络及本地网络权限。"
    case .http(let code): return "网关返回 HTTP \(code)。"
    case .response: return "网关响应格式异常。"
    case .device: return "无法唯一确认当前设备。"
    case .config: return "当前认证配置暂不支持，请使用学校登录页。"
    case .credentials: return "请输入账号和密码。"
    case .rejected: return "网关拒绝了请求，请检查账号和校园网状态。"
    case .startupNetwork: return "仅在 ksu-Wlan 上自动连接。请检查 Wi-Fi 和定位权限。"
    case .sessionChanged: return "当前在线账号已变化，请重新选择操作。"
    case .uncertain: return "请求结果待确认，请先刷新状态。"
    }
  }
}

typealias Query = [String: String]
typealias Transport = (Gateway, GatewayOperation, Query) async throws -> String

#if SWIFT_PACKAGE
  import CampusHTTP
#endif

struct DirectHTTP {
  static let shared = DirectHTTP()

  static func request(_ gateway: Gateway, _ op: GatewayOperation, _ query: Query) throws
    -> URLRequest
  {
    var url = URLComponents()
    url.scheme = "http"
    url.host = gateway.rawValue
    url.port = op.port
    url.path = op == .page ? gateway.page : op.rawValue
    let safe = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    func encode(_ s: String) throws -> String {
      guard let value = s.addingPercentEncoding(withAllowedCharacters: safe) else {
        throw PortalError.response
      }
      return value
    }
    if !query.isEmpty {
      url.percentEncodedQuery = try query.sorted { $0.key < $1.key }.map {
        try encode($0.key) + "=" + encode($0.value)
      }.joined(separator: "&")
    }
    guard let endpoint = url.url else { throw PortalError.response }
    var request = URLRequest(url: endpoint)
    request.setValue("http://" + gateway.rawValue + gateway.page, forHTTPHeaderField: "Referer")
    return request
  }

  func send(_ gateway: Gateway, _ op: GatewayOperation, _ query: Query) async throws -> String {
    try await fetch(Self.request(gateway, op, query))
  }

  func fetch(_ request: URLRequest) async throws -> String {
    guard let url = request.url?.absoluteString else { throw PortalError.response }
    let referer = request.value(forHTTPHeaderField: "Referer")
    return try await withCheckedThrowingContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        var response = CampusResponse()
        let code = campus_http_get(url, referer, &response)
        defer { free(response.bytes) }
        if response.over_limit != 0 {
          cont.resume(throwing: PortalError.response)
          return
        }
        guard code == 0 else {
          cont.resume(throwing: PortalError.network(Int(code)))
          return
        }
        guard response.status == 200 else {
          cont.resume(throwing: PortalError.http(response.status))
          return
        }
        let bytes = response.bytes.map { Data(bytes: $0, count: response.size) } ?? Data()
        let gb = String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: bytes, encoding: response.gb_encoding == 0 ? .utf8 : gb)
        else {
          cont.resume(throwing: PortalError.response)
          return
        }
        cont.resume(returning: text)
      }
    }
  }
}
