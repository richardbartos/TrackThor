import Foundation

/// Clockify data region. Workspaces with a data region set must use the regional host.
enum ClockifyRegion: String, CaseIterable, Identifiable, Sendable {
  case global
  case eu
  case us
  case uk
  case au

  var id: String { rawValue }

  var title: String {
    switch self {
    case .global: return "Global (default)"
    case .eu: return "EU (Germany)"
    case .us: return "USA"
    case .uk: return "UK"
    case .au: return "Australia"
    }
  }

  var baseURL: URL {
    switch self {
    case .global: return URL(string: "https://api.clockify.me/api/v1")!
    case .eu: return URL(string: "https://euc1.clockify.me/api/v1")!
    case .us: return URL(string: "https://use2.clockify.me/api/v1")!
    case .uk: return URL(string: "https://euw2.clockify.me/api/v1")!
    case .au: return URL(string: "https://apse2.clockify.me/api/v1")!
    }
  }
}

struct ClockifyUser: Decodable, Sendable {
  let id: String
  let name: String?
  let email: String?
  let activeWorkspace: String?
  let defaultWorkspace: String?
}

struct ClockifyWorkspace: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
}

struct ClockifyProject: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let clientName: String?
  let archived: Bool?

  /// "MEETING – PRODUCT TEAM"
  var displayName: String {
    guard let clientName, !clientName.isEmpty else { return name }
    return "\(name) – \(clientName)"
  }
}

struct ClockifyTimeEntry: Decodable, Sendable {
  struct Interval: Decodable, Sendable {
    let start: Date
    let end: Date?
  }

  let id: String
  let projectId: String?
  let timeInterval: Interval
}

struct ClockifyNewTimeEntry: Encodable, Sendable {
  let start: String
  let end: String
  let billable: Bool
  let description: String?
  let projectId: String
}

enum ClockifyError: LocalizedError {
  case missingAPIKey
  case notConfigured(String)
  case invalidResponse
  case http(status: Int, message: String?)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Add your Clockify API key in Settings."
    case .notConfigured(let what):
      return "Clockify isn't set up yet: \(what)."
    case .invalidResponse:
      return "Clockify sent an unexpected response."
    case .http(let status, let message):
      let detail = message.map { " (\($0))" } ?? ""
      switch status {
      case 401: return "Clockify rejected the API key\(detail)."
      case 403: return "The API key has no access to this workspace\(detail)."
      case 404: return "Not found in Clockify\(detail). If your workspace uses a data region, pick it in Settings."
      case 429: return "Clockify rate limit reached — try again in a moment\(detail)."
      default: return "Clockify error \(status)\(detail)."
      }
    }
  }
}

/// Thin client for the Clockify REST API v1 (https://docs.clockify.me). Auth: `X-Api-Key` header.
struct ClockifyClient: Sendable {
  let apiKey: String
  let region: ClockifyRegion

  private static let pageSize = 200

  func currentUser() async throws -> ClockifyUser {
    try await get("user")
  }

  func workspaces() async throws -> [ClockifyWorkspace] {
    try await get("workspaces")
  }

  func projects(workspaceId: String) async throws -> [ClockifyProject] {
    try await getAllPages(
      "workspaces/\(workspaceId)/projects",
      query: [URLQueryItem(name: "archived", value: "false")]
    )
  }

  func timeEntries(workspaceId: String, userId: String, from start: Date, to end: Date) async throws -> [ClockifyTimeEntry] {
    try await getAllPages(
      "workspaces/\(workspaceId)/user/\(userId)/time-entries",
      query: [
        URLQueryItem(name: "start", value: Self.timestamp(start)),
        URLQueryItem(name: "end", value: Self.timestamp(end))
      ]
    )
  }

  func createTimeEntry(workspaceId: String, _ entry: ClockifyNewTimeEntry) async throws -> ClockifyTimeEntry {
    let body = try JSONEncoder().encode(entry)
    let (data, _) = try await perform(request("POST", "workspaces/\(workspaceId)/time-entries", body: body))
    return try Self.decoder.decode(ClockifyTimeEntry.self, from: data)
  }

  /// Deleting an entry that no longer exists is not an error.
  func deleteTimeEntry(workspaceId: String, id: String) async throws {
    do {
      _ = try await perform(request("DELETE", "workspaces/\(workspaceId)/time-entries/\(id)"))
    } catch ClockifyError.http(status: 404, _) {
      return
    }
  }

  /// Clockify expects UTC ISO-8601, e.g. 2026-11-09T08:15:00Z.
  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  // MARK: - Plumbing

  private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
    let (data, _) = try await perform(request("GET", path, query: query))
    return try Self.decoder.decode(T.self, from: data)
  }

  private func getAllPages<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
    var results: [T] = []
    for page in 1...100 {
      let pageQuery = query + [
        URLQueryItem(name: "page", value: String(page)),
        URLQueryItem(name: "page-size", value: String(Self.pageSize))
      ]
      let (data, response) = try await perform(request("GET", path, query: pageQuery))
      let items = try Self.decoder.decode([T].self, from: data)
      results.append(contentsOf: items)

      let isLastPage = response.value(forHTTPHeaderField: "Last-Page")?.lowercased() == "true"
      if isLastPage || items.count < Self.pageSize {
        break
      }
    }
    return results
  }

  private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
    guard var components = URLComponents(url: region.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
      throw ClockifyError.invalidResponse
    }
    if !query.isEmpty {
      components.queryItems = query
    }
    guard let url = components.url else { throw ClockifyError.invalidResponse }

    var request = URLRequest(url: url, timeoutInterval: 30)
    request.httpMethod = method
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ClockifyError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw ClockifyError.http(status: http.statusCode, message: Self.errorMessage(from: data))
    }
    return (data, http)
  }

  private static func errorMessage(from data: Data) -> String? {
    struct Body: Decodable { let message: String? }
    if let message = (try? JSONDecoder().decode(Body.self, from: data))?.message, !message.isEmpty {
      return message
    }
    let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text?.isEmpty == false ? String(text!.prefix(200)) : nil
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let string = try container.decode(String.self)
      let plain = ISO8601DateFormatter()
      let fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = plain.date(from: string) ?? fractional.date(from: string) {
        return date
      }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unexpected date: \(string)")
    }
    return decoder
  }()
}
