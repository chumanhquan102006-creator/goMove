import '../../../../core/utils/result.dart';
import '../entities/user.dart';
import '../repositories/auth_repository.dart';

class RegisterUseCase {
  final AuthRepository _repository;

  RegisterUseCase(this._repository);

  Future<Result<User>> call({
    required String phone,
    String? email,
    required String password,
    required String fullName,
  }) {
    return _repository.register(
      phone: phone,
      email: email,
      password: password,
      fullName: fullName,
    );
  }
}
