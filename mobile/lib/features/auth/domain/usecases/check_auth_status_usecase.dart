import '../../../../core/utils/result.dart';
import '../entities/user.dart';
import '../repositories/auth_repository.dart';

class CheckAuthStatusUseCase {
  final AuthRepository _repository;

  CheckAuthStatusUseCase(this._repository);

  Future<Result<User>> call() {
    return _repository.checkAuthStatus();
  }
}
