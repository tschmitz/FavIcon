//
// FavIcon
// Copyright © 2016 Leon Breedt
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

/// Enumerates the possible results of a `URLRequestOperation`.
enum URLResult {
    /// Plain text content was downloaded successfully.
    /// - parameters:
    ///   - url: The actual URL the content was downloaded from, after any redirects.
    ///   - text: The text content.
    ///   - mimeType: The MIME type of the text content (e.g. `application/json`).
    case TextDownloaded(url: URL, text: String, mimeType: String)
    /// Image content was downloaded successfully.
    /// - parameters:
    ///   - url: The actual URL the content was downloaded from, after any redirects.
    ///   - image: The downloaded image.
    case ImageDownloaded(url: URL, image: ImageType)
    /// The URL request was successful (HTTP 200 response).
    /// - parameters:
    ///   - url: The actual URL, after any redirects.
    case Success(url: URL)
    /// The URL request failed for some reason.
    /// - parameters:
    ///   - error: The error that occurred.
    case Failed(error: ErrorProtocol)
}

/// Enumerates well known errors that may occur while executing a `URLRequestOperation`.
enum URLRequestError: ErrorProtocol {
    /// No response was received from the server.
    case MissingResponse
    /// The file was not found (HTTP 404 response).
    case FileNotFound
    /// The request succeeded, but the content was not plain text when it was expected to be.
    case NotPlainText
    /// The request succeeded, but the content encoding could not be determined, or was malformed.
    case InvalidTextEncoding
    /// The request succeeded, but the MIME type of the response is not a supported image format.
    case UnsupportedImageFormat(mimeType: String)
    /// An unexpected HTTP error response was returned.
    /// - parameters:
    ///   - response: The `HTTPURLResponse` that can be consulted for further information.
    case HTTPError(response: HTTPURLResponse)
}

/// Base class for performing URL requests in the context of an `NSOperation`.
class URLRequestOperation: Operation {
    var urlRequest: URLRequest
    var result: URLResult?

    private var task: URLSessionDataTask?
    private let session: URLSession
    private var semaphore: DispatchSemaphore?

    init(url: URL, session: URLSession) {
        self.session = session
        self.urlRequest = URLRequest(url: url)
        self.semaphore = nil
    }

    override func main() {
        semaphore = DispatchSemaphore(value: 0)
        prepareRequest()
        task = session.dataTask(with: urlRequest, completionHandler: dataTaskCompletion)
        task?.resume()
        semaphore?.wait()
    }

    override func cancel() {
        task?.cancel()
        if let semaphore = semaphore {
            semaphore.signal()
        }
    }

    func prepareRequest() {
    }

    func processResult(data: Data?, response: HTTPURLResponse, completion: (URLResult) -> Void) {
        fatalError("must override processResult()")
    }

    private func dataTaskCompletion(data: Data?, response: URLResponse?, error: NSError?) {
        guard error == nil else {
            result = .Failed(error: error!)
            self.notifyFinished()
            return
        }

        guard let response = response as? HTTPURLResponse else {
            result = .Failed(error: URLRequestError.MissingResponse)
            self.notifyFinished()
            return
        }

        if response.statusCode == 404 {
            result = .Failed(error: URLRequestError.FileNotFound)
            self.notifyFinished()
            return
        }

        if response.statusCode < 200 || response.statusCode > 299 {
            result = .Failed(error: URLRequestError.HTTPError(response: response))
            self.notifyFinished()
            return
        }

        processResult(data: data, response: response) { result in
            // This block may run on another thread long after dataTaskCompletion() finishes! So
            // wait until then to signal semaphore if we get past checks above.
            self.result = result
            self.notifyFinished()
        }
    }

    private func notifyFinished() {
        if let semaphore = self.semaphore {
            semaphore.signal()
        }
    }
}

typealias URLRequestWithCallback = (request: URLRequestOperation, completion: (URLResult) -> Void)

func executeURLOperations(operations: [URLRequestOperation],
                          concurrency: Int = 2,
                          on queue: OperationQueue? = nil,
                          completion: ([URLResult]) -> Void) {
    guard operations.count > 0 else {
        completion([])
        return
    }

    let queue = queue ?? OperationQueue()
    queue.isSuspended = true
    queue.maxConcurrentOperationCount = concurrency

    let completionOperation = BlockOperation {
        completion(operations.map { $0.result! })
    }
    for operation in operations {
        queue.addOperation(operation)
        completionOperation.addDependency(operation)
    }
    queue.addOperation(completionOperation)

    queue.isSuspended = false
}

func executeURLOperations(operations: [URLRequestWithCallback],
                          concurrency: Int = 2,
                          on queue: OperationQueue? = nil,
                          completion: () -> Void) {
    guard operations.count > 0 else { return }

    let queue = queue ?? OperationQueue()
    queue.isSuspended = true
    queue.maxConcurrentOperationCount = concurrency

    let overallCompletion = BlockOperation {
        completion()
    }

    for operation in operations {
        let operationCompletion = BlockOperation {
            operation.completion(operation.request.result!)
        }
        queue.addOperation(operation.request)
        operationCompletion.addDependency(operation.request)
        queue.addOperation(operationCompletion)
        overallCompletion.addDependency(operationCompletion)
    }
    queue.addOperation(overallCompletion)

    queue.isSuspended = false
}

func urlRequestOperation(operation: URLRequestOperation,
                         completion: (URLResult) -> Void) -> URLRequestWithCallback {
    return (request: operation, completion: completion)
}
