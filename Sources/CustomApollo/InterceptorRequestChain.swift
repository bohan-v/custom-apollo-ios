import Foundation
#if !COCOAPODS
import CustomApolloAPI
#endif

/// A chain that allows a single network request to be created and executed.
final public class InterceptorRequestChain: Cancellable, RequestChain {

  public enum ChainError: Error, LocalizedError {
    case invalidIndex(chain: RequestChain, index: Int)
    case noInterceptors

    public var errorDescription: String? {
      switch self {
      case .noInterceptors:
        return "No interceptors were provided to this chain. This is a developer error."
      case .invalidIndex(_, let index):
        return "`proceedAsync` was called for index \(index), which is out of bounds of the receiver for this chain. Double-check the order of your interceptors."
      }
    }
  }

  private var interceptors: [ApolloInterceptorReentrantWrapper]
  private var callbackQueue: DispatchQueue
  @Atomic public var isCancelled: Bool = false

  private var managedSelf: Unmanaged<InterceptorRequestChain>!

  /// Something which allows additional error handling to occur when some kind of error has happened.
  public var additionalErrorHandler: ApolloErrorInterceptor?

  /// Creates a chain with the given interceptor array.
  ///
  /// - Parameters:
  ///   - interceptors: The array of interceptors to use.
  ///   - callbackQueue: The `DispatchQueue` to call back on when an error or result occurs.
  ///   Defaults to `.main`.
  public init(
    interceptors: [ApolloInterceptor],
    callbackQueue: DispatchQueue = .main
  ) {
    self.interceptors = []
    self.callbackQueue = callbackQueue

    managedSelf = Unmanaged<InterceptorRequestChain>.passRetained(self)

    self.interceptors = interceptors.enumerated().map { (index, interceptor) in
      ApolloInterceptorReentrantWrapper(
        interceptor: interceptor,
        requestChain: managedSelf,
        index: index
      )
    }
  }

  /// Kicks off the request from the beginning of the interceptor array.
  ///
  /// - Parameters:
  ///   - request: The request to send.
  ///   - completion: The completion closure to call when the request has completed.
  public func kickoff<Operation: GraphQLOperation>(
    request: HTTPRequest<Operation>,
    completion: @escaping (Result<GraphQLResult<Operation.Data>, Error>) -> Void
  ) {
    guard let firstInterceptor = self.interceptors.first else {
      handleErrorAsync(
        ChainError.noInterceptors,
        request: request,
        response: nil,
        completion: completion
      )
      return
    }

    firstInterceptor.interceptAsync(
      chain: self,
      request: request,
      response: nil,
      completion: completion
    )
  }

  /// Proceeds to the next interceptor in the array.
  ///
  /// - Parameters:
  ///   - request: The in-progress request object
  ///   - response: [optional] The in-progress response object, if received yet
  ///   - completion: The completion closure to call when data has been processed and should be
  ///   returned to the UI.
  public func proceedAsync<Operation: GraphQLOperation>(
    request: HTTPRequest<Operation>,
    response: HTTPResponse<Operation>?,
    completion: @escaping (Result<GraphQLResult<Operation.Data>, Error>) -> Void
  ) {
      // Empty implementation, proceedAsync(request:response:completion:interceptor:) should be
      // used instead.
  }

  /// Proceeds to the next interceptor in the array.
  ///
  /// - Parameters:
  ///   - request: The in-progress request object
  ///   - response: [optional] The in-progress response object, if received yet
  ///   - completion: The completion closure to call when data has been processed and should be
  ///   returned to the UI.
  ///   - interceptor: The interceptor that has completed processing and is ready to pass control
  ///   on to the next interceptor in the chain.
  func proceedAsync<Operation: GraphQLOperation>(
    request: HTTPRequest<Operation>,
    response: HTTPResponse<Operation>?,
    completion: @escaping (Result<GraphQLResult<Operation.Data>, Error>) -> Void,
    interceptor: ApolloInterceptorReentrantWrapper
  ) {
    guard !self.isCancelled else {
      // Do not proceed, this chain has been cancelled.
      return
    }

    let nextIndex = interceptor.index + 1
    if self.interceptors.indices.contains(nextIndex) {
      let interceptor = self.interceptors[nextIndex]

      interceptor.interceptAsync(
        chain: self,
        request: request,
        response: response,
        completion: completion
      )
    } else {
      if let result = response?.parsedResponse {
        // We got to the end of the chain with a parsed response. Yay! Return it.
        self.returnValueAsync(
          for: request,
          value: result,
          completion: completion
        )

        if Operation.operationType != .subscription {
          self.managedSelf.release()
        }
      } else {
        // We got to the end of the chain and no parsed response is there, there needs to be more
        // processing.
        self.handleErrorAsync(
          ChainError.invalidIndex(chain: self, index: nextIndex),
          request: request,
          response: response,
          completion: completion
        )
      }
    }
  }

  /// Cancels the entire chain of interceptors.
  public func cancel() {
    guard !self.isCancelled else {
      // Do not proceed, this chain has been cancelled.
      return
    }

    self.$isCancelled.mutate { $0 = true }

    // If an interceptor adheres to `Cancellable`, it should have its in-flight work cancelled as
    // well.
    for interceptor in self.interceptors {
      interceptor.cancel()
    }

    self.managedSelf.release()
  }

  /// Restarts the request starting from the first interceptor.
  ///
  /// - Parameters:
  ///   - request: The request to retry
  ///   - completion: The completion closure to call when the request has completed.
  public func retry<Operation: GraphQLOperation>(
    request: HTTPRequest<Operation>,
    completion: @escaping (Result<GraphQLResult<Operation.Data>, Error>) -> Void
  ) {
    guard !self.isCancelled else {
      // Don't retry something that's been cancelled.
      return
    }

    self.kickoff(request: request, completion: completion)
  }

  /// Handles the error by returning it on the appropriate queue, or by applying an additional
  /// error interceptor if one has been provided.
  ///
  /// - Parameters:
  ///   - error: The error to handle
  ///   - request: The request, as far as it has been constructed.
  ///   - response: The response, as far as it has been constructed.
  ///   - completion: The completion closure to call when work is complete.
  public func handleErrorAsync<Operation: GraphQLOperation>(
    _ error: Error,
    request: HTTPRequest<Operation>,
    response: HTTPResponse<Operation>?,
    completion: @escaping (Result<GraphQLResult<Operation.Data>, Error>) -> Void
  ) {
    guard !self.isCancelled else {
      return
    }

    guard let additionalHandler = self.additionalErrorHandler else {
      self.callbackQueue.async {
        completion(.failure(error))
      }
      return
    }

    // Capture callback queue so it doesn't get reaped when `self` is dealloced
    let callbackQueue = self.callbackQueue
    additionalHandler.handleErrorAsync(
      error: error,
      chain: self,
      request: request,
      response: response
    ) { result in
      callbackQueue.async {
        completion(result)
      }
    }
  }

  /// Handles a resulting value by returning it on the appropriate queue.
  ///
  /// - Parameters:
  ///   - request: The request, as far as it has been constructed.
  ///   - value: The value to be returned
  ///   - completion: The completion closure to call when work is complete.
  public func returnValueAsync<Operation: GraphQLOperation>(
    for request: HTTPRequest<Operation>,
    value: GraphQLResult<Operation.Data>,
    completion: @escaping (Result<GraphQLResult<Operation.Data>, Error>) -> Void
  ) {
    guard !self.isCancelled else {
      return
    }

    self.callbackQueue.async {
      completion(.success(value))
    }
  }
}
