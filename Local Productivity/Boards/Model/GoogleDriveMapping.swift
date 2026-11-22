//
//  GoogleDriveMapping.swift
//  LP
//
//  Sharing a board's progress page through the person's own Google Drive: the requests LP sends
//  (create a Google Doc from the page, let anyone with the link view it, replace its content,
//  delete it) and how to read the replies. Pure data, like GoogleCalendarMapping; the app side is
//  GoogleDrivePublisher. LP only ever has Google's `drive.file` permission: it can see and change
//  the files it created, nothing else in the Drive.
//

import Foundation

nonisolated enum GoogleDriveMapping {

    static let uploadBase = URL(string: "https://www.googleapis.com/upload/drive/v3/files")!
    static let apiBase = URL(string: "https://www.googleapis.com/drive/v3/files")!
    /// What Google turns the uploaded page into: a Google Doc, which anyone with its link can read
    /// in a browser (Drive shows an HTML file as code).
    static let documentType = "application/vnd.google-apps.document"

    enum Problem: Error, Equatable {
        case unreadable
    }

    // MARK: IDs and addresses

    /// Drive file IDs: letters, digits, "-" and "_" — never a path or an address.
    static func isValidFileID(_ id: String) -> Bool {
        (10...100).contains(id.count) && id.unicodeScalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || scalar == "-" || scalar == "_"
        }
    }

    /// The page's address, made from its ID — never taken from a reply or a board's history.
    static func pageURL(fileID: String) -> URL? {
        isValidFileID(fileID) ? URL(string: "https://docs.google.com/document/d/\(fileID)/view") : nil
    }

    // MARK: Requests

    /// Creates the page: the HTML becomes a Google Doc named `name`.
    static func createRequest(name: String, html: String, boundary: String) -> URLRequest {
        multipart("POST", url(uploadBase, ["uploadType": "multipart", "fields": "id"]),
                  metadata: ["name": name, "mimeType": documentType], html: html, boundary: boundary)
    }

    /// Replaces the page's content (and its name, if the board was renamed), keeping its address.
    static func updateRequest(fileID: String, name: String, html: String, boundary: String) -> URLRequest? {
        guard isValidFileID(fileID) else { return nil }
        return multipart("PATCH", url(uploadBase.appendingPathComponent(fileID), ["uploadType": "multipart", "fields": "id"]),
                         metadata: ["name": name], html: html, boundary: boundary)
    }

    /// Lets anyone with the link view the page — without signing in, and without it being listed
    /// or searchable.
    static func publishRequest(fileID: String) -> URLRequest? {
        guard isValidFileID(fileID) else { return nil }
        var request = URLRequest(url: url(apiBase.appendingPathComponent(fileID).appendingPathComponent("permissions"), ["fields": "id"]))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["type": "anyone", "role": "reader", "allowFileDiscovery": false],
                                                       options: [.sortedKeys])
        return request
    }

    static func deleteRequest(fileID: String) -> URLRequest? {
        guard isValidFileID(fileID) else { return nil }
        var request = URLRequest(url: apiBase.appendingPathComponent(fileID))
        request.httpMethod = "DELETE"
        return request
    }

    /// A boundary for one request, which no page can contain by accident.
    static func boundary() -> String { "lp-" + UUID().uuidString }

    // MARK: Replies

    /// The new file's ID — only if it is one.
    static func fileID(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, isValidFileID(id) else { throw Problem.unreadable }
        return id
    }

    // MARK: Building

    private static func url(_ base: URL, _ query: [String: String]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private static func multipart(_ method: String, _ url: URL, metadata: [String: String], html: String, boundary: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let meta = (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data("{}".utf8)
        var body = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        body.append(meta)
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n".utf8))
        body.append(Data(html.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }
}
