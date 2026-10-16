import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/config/app_config.dart';
import '../../../../core/di/injection.dart';
import '../bloc/onboarding_cubit.dart';

class DriverOnboardingScreen extends StatelessWidget {
  const DriverOnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
      create: (_) => sl<OnboardingCubit>(), child: const _OnboardingForm());
}

class _OnboardingForm extends StatefulWidget {
  const _OnboardingForm();
  @override
  State<_OnboardingForm> createState() => _OnboardingFormState();
}

class _OnboardingFormState extends State<_OnboardingForm> {
  final _license = TextEditingController();
  @override
  void dispose() {
    _license.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Đăng ký làm tài xế')),
        body: BlocBuilder<OnboardingCubit, OnboardingState>(
            builder: (context, state) =>
                ListView(padding: const EdgeInsets.all(20), children: [
                  const Text(
                      'Tài khoản Customer hiện tại có thể gửi yêu cầu làm tài xế. '
                      'Admin phải phê duyệt trước khi bạn được trực tuyến.'),
                  const SizedBox(height: 16),
                  if (state.submitted)
                    const Card(
                        child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                          'Đã gửi yêu cầu. Trạng thái: chờ Admin phê duyệt. '
                          'Hãy đăng xuất và đăng nhập lại để nhận JWT vai trò DRIVER mới. '
                          'Ứng dụng không tự phê duyệt tài xế.'),
                    ))
                  else if (!state.uncertain) ...[
                    TextField(
                        controller: _license,
                        decoration: const InputDecoration(
                            labelText: 'Số giấy phép lái xe',
                            border: OutlineInputBorder())),
                    const SizedBox(height: 12),
                    FilledButton(
                        onPressed: state.loading || AppConfig.instance.isMock
                            ? null
                            : () {
                                if (_license.text.trim().isNotEmpty) {
                                  context
                                      .read<OnboardingCubit>()
                                      .submit(_license.text);
                                }
                              },
                        child: state.loading
                            ? const CircularProgressIndicator()
                            : const Text('Gửi yêu cầu')),
                  ],
                  if (AppConfig.instance.isMock)
                    const Text(
                        'Cần MOCK_ENABLED=false để dùng onboarding thật.'),
                  if (state.error != null)
                    Text(state.error!,
                        style: const TextStyle(color: Colors.red)),
                ])),
      );
}
