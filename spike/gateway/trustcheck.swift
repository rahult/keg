// URLSession fetch probe — replicates Safari's trust evaluation path (CFNetwork),
// unlike /usr/bin/curl which may use its own CA bundle.
//
//   swift trustcheck.swift https://memos.keg/
import Foundation

guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) else {
    print("usage: trustcheck <url>")
    exit(2)
}
let done = DispatchSemaphore(value: 0)
var request = URLRequest(url: url)
request.timeoutInterval = 8
URLSession.shared.dataTask(with: request) { data, response, error in
    if let error {
        print("FAIL \(url.absoluteString): \(error.localizedDescription)\n  [\(error)]")
    } else if let http = response as? HTTPURLResponse {
        print("OK \(url.absoluteString): HTTP \(http.statusCode), \(data?.count ?? 0) bytes")
    } else {
        print("FAIL: non-HTTP response")
    }
    done.signal()
}.resume()
done.wait()
