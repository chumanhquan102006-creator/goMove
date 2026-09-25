import '../error/failures.dart';

/// Đại diện cho kết quả thực thi một thao tác nghiệp vụ: Thành công (Success) hoặc Thất bại (Error).
/// Thiết kế theo chuẩn Sealed Class của Dart 3, hỗ trợ exhaustive pattern matching an toàn tuyệt đối.
sealed class Result<T> {
  const Result();

  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Error<T>;

  T? get dataOrNull => switch (this) {
        Success<T>(data: final data) => data,
        Error<T>() => null,
      };

  Failure? get failureOrNull => switch (this) {
        Success<T>() => null,
        Error<T>(failure: final failure) => failure,
      };

  R fold<R>({
    required R Function(T data) onSuccess,
    required R Function(Failure failure) onFailure,
  }) {
    return switch (this) {
      Success<T>(data: final data) => onSuccess(data),
      Error<T>(failure: final failure) => onFailure(failure),
    };
  }
}

/// Trạng thái thực thi thành công chứa dữ liệu trả về kiểu [T]
final class Success<T> extends Result<T> {
  final T data;
  const Success(this.data);
}

/// Trạng thái thực thi thất bại mang theo đối tượng [Failure]
final class Error<T> extends Result<T> {
  final Failure failure;
  const Error(this.failure);
}
