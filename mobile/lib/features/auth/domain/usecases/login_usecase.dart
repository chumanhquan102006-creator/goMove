import '../../../../core/utils/result.dart';
import '../entities/user.dart';
import '../repositories/auth_repository.dart';

class LoginUseCase {
  final AuthRepository _repository;

  LoginUseCase(this._repository);

  Future<Result<User>> call({
    required String identifier,
    required String password,
  }) {
    return _repository.login(
      identifier: identifier,
      password: password,
    );
  }
}
