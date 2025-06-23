import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'register_screen.dart';
import 'home_screen.dart';
import 'config.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  _LoginScreenState createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  String? _errorMessage;
  bool _isLoading = false;
  bool _isPasswordVisible = false;
  bool _isGoogleLoading = false;

  // Animation controller
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    // Thêm animation cho form
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeIn,
      ),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  // Email validation
  String? _validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Vui lòng nhập email';
    }

    final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
    if (!emailRegex.hasMatch(value)) {
      return 'Email không hợp lệ';
    }

    return null;
  }

  // Password validation
  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Vui lòng nhập mật khẩu';
    }

    if (value.length < 6) {
      return 'Mật khẩu phải có ít nhất 6 ký tự';
    }

    return null;
  }

  // Clear error message
  void _clearErrorMessage() {
    if (_errorMessage != null) {
      setState(() {
        _errorMessage = null;
      });
    }
  }

  // Handle errors
  String _getErrorMessage(dynamic error, int? statusCode) {
    if (statusCode != null) {
      switch (statusCode) {
        case 400:
          return 'Thông tin đăng nhập không hợp lệ';
        case 401:
          return 'Email hoặc mật khẩu không chính xác';
        case 403:
          return 'Tài khoản đã bị khóa';
        case 404:
          return 'Tài khoản không tồn tại';
        case 429:
          return 'Quá nhiều lần thử. Vui lòng thử lại sau';
        case 500:
          return 'Lỗi server. Vui lòng thử lại sau';
        default:
          return 'Đăng nhập thất bại';
      }
    }

    if (error.toString().contains('network')) {
      return 'Lỗi kết nối mạng. Vui lòng kiểm tra internet';
    }

    if (error.toString().contains('timeout')) {
      return 'Kết nối quá chậm. Vui lòng thử lại';
    }

    return 'Có lỗi xảy ra: ${error.toString()}';
  }

  // Đăng nhập bằng email và mật khẩu
  Future<void> _login() async {
    _clearErrorMessage();

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/login'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'email': _emailController.text.trim().toLowerCase(),
          'password': _passwordController.text,
        }),
      ).timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final uid = data['uid'] as String?;
        final token = data['token'] as String?;

        if (uid == null || token == null) {
          throw Exception('Dữ liệu không hợp lệ từ server');
        }

        _emailController.clear();
        _passwordController.clear();

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => HomeScreen(
                uid: uid,
                token: token,
              ),
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = data['error'] ?? _getErrorMessage(null, response.statusCode);
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = _getErrorMessage(e, null);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // Đăng nhập bằng Google
  Future<void> _googleSignIn() async {
    _clearErrorMessage();

    setState(() {
      _isGoogleLoading = true;
    });

    try {
      final GoogleSignIn googleSignIn = GoogleSignIn();
      await googleSignIn.signOut();

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        return;
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      if (googleAuth.accessToken == null || googleAuth.idToken == null) {
        throw Exception('Không thể lấy thông tin xác thực từ Google');
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCredential = await FirebaseAuth.instance.signInWithCredential(credential);
      final idToken = await userCredential.user!.getIdToken();

      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/google-signin'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'idToken': idToken}),
      ).timeout(const Duration(seconds: 30));

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        final uid = data['uid'] as String?;
        final token = data['token'] as String?;

        if (uid == null || token == null) {
          throw Exception('Dữ liệu không hợp lệ từ server');
        }

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => HomeScreen(
                uid: uid,
                token: token,
              ),
            ),
          );
        }
      } else {
        setState(() {
          _errorMessage = data['error'] ?? _getErrorMessage(null, response.statusCode);
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = _getErrorMessage(e, null);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final isSmallScreen = screenSize.width < 360;

    // Bảng màu đồng bộ với WelcomeScreen
    final Color primaryColor = Color(0xFF0078D7);      // Microsoft Blue
    final Color secondaryColor = Color(0xFF50E3C2);    // Mint
    final Color accentColor = Color(0xFF00B294);       // Teal
    final Color textDarkColor = Color(0xFF202124);
    final Color textLightColor = Color(0xFF5F6368);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE6F7FF), Colors.white],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isSmallScreen ? 16.0 : 20.0,
                vertical: 16.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Back button
                  Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      icon: Icon(Icons.arrow_back_ios, color: primaryColor),
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Quay lại',
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(),
                      iconSize: 22,
                    ),
                  ),

                  SizedBox(height: 16),

                  // Logo và tên app - đặt cạnh nhau theo chiều ngang
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Icon tủ lạnh với màu mới đẹp hơn
                      Container(
                        padding: EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            colors: [accentColor, primaryColor],
                            radius: 0.8,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withOpacity(0.3),
                              blurRadius: 8,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.kitchen,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),

                      const SizedBox(width: 10),

                      // Tên app với gradient đẹp
                      ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          colors: [primaryColor, secondaryColor],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ).createShader(bounds),
                        child: Text(
                          'SmartFri',
                          style: TextStyle(
                            fontSize: isSmallScreen ? 30 : 32,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: 24),

                  // Tiêu đề đăng nhập
                  Text(
                    'Đăng nhập',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: textDarkColor,
                    ),
                  ),

                  SizedBox(height: 24),

                  // Form đăng nhập với animation
                  FadeTransition(
                    opacity: _fadeAnimation,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.05),
                            blurRadius: 15,
                            offset: Offset(0, 5),
                          ),
                        ],
                      ),
                      padding: EdgeInsets.all(20),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Email field
                            Text(
                              'Email',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: textDarkColor,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _emailController,
                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,
                              onChanged: (_) => _clearErrorMessage(),
                              decoration: InputDecoration(
                                hintText: 'Nhập email của bạn',
                                prefixIcon: Icon(Icons.email_outlined, color: primaryColor, size: 20),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Colors.grey[50],
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 16,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: primaryColor, width: 1.5),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                ),
                              ),
                              validator: _validateEmail,
                            ),

                            const SizedBox(height: 16),

                            // Password field
                            Text(
                              'Mật khẩu',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: textDarkColor,
                              ),
                            ),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _passwordController,
                              textInputAction: TextInputAction.done,
                              onChanged: (_) => _clearErrorMessage(),
                              onFieldSubmitted: (_) => _login(),
                              decoration: InputDecoration(
                                hintText: 'Nhập mật khẩu của bạn',
                                prefixIcon: Icon(Icons.lock_outline, color: primaryColor, size: 20),
                                suffixIcon: IconButton(
                                  icon: Icon(
                                    _isPasswordVisible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    color: Colors.grey[600],
                                    size: 20,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      _isPasswordVisible = !_isPasswordVisible;
                                    });
                                  },
                                  tooltip: _isPasswordVisible ? 'Ẩn mật khẩu' : 'Hiện mật khẩu',
                                  padding: EdgeInsets.zero,
                                  constraints: BoxConstraints(),
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                filled: true,
                                fillColor: Colors.grey[50],
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 16,
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: primaryColor, width: 1.5),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                ),
                              ),
                              obscureText: !_isPasswordVisible,
                              validator: _validatePassword,
                            ),

                            // Quên mật khẩu
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () {
                                  // Xử lý quên mật khẩu
                                },
                                style: TextButton.styleFrom(
                                  padding: EdgeInsets.symmetric(vertical: 4),
                                  minimumSize: Size(0, 0),
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                child: Text(
                                  'Quên mật khẩu?',
                                  style: TextStyle(
                                    color: primaryColor,
                                    fontWeight: FontWeight.w500,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),

                            // Error message
                            if (_errorMessage != null)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(10),
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: Colors.red[50],
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.red[200]!),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.error_outline, color: Colors.red[600], size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _errorMessage!,
                                        style: TextStyle(
                                          color: Colors.red[700],
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                            const SizedBox(height: 8),

                            // Login button
                            Container(
                              width: double.infinity,
                              height: 48,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [primaryColor, accentColor],
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: primaryColor.withOpacity(0.3),
                                    blurRadius: 8,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _login,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  disabledBackgroundColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding: EdgeInsets.zero,
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                )
                                    : const Text(
                                  'Đăng nhập',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Đăng ký tài khoản
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const RegisterScreen(),
                        ),
                      );
                    },
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      minimumSize: Size(0, 0),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: RichText(
                      text: TextSpan(
                        text: 'Chưa có tài khoản? ',
                        style: TextStyle(
                          color: textLightColor,
                          fontSize: 14,
                        ),
                        children: [
                          TextSpan(
                            text: 'Đăng ký ngay',
                            style: TextStyle(
                              color: primaryColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  SizedBox(height: 16),

                  // Separator
                  Row(
                    children: [
                      Expanded(child: Divider(color: Colors.grey[300])),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'Hoặc đăng nhập với',
                          style: TextStyle(
                            color: textLightColor,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(child: Divider(color: Colors.grey[300])),
                    ],
                  ),

                  SizedBox(height: 16),

                  // Social login buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildSocialLoginCircleButton(
                        icon: FontAwesomeIcons.google,
                        iconColor: const Color(0xFFDB4437),
                        backgroundColor: Colors.white,
                        onPressed: _isGoogleLoading ? null : _googleSignIn,
                        isLoading: _isGoogleLoading,
                      ),
                      const SizedBox(width: 16),
                      _buildSocialLoginCircleButton(
                        icon: FontAwesomeIcons.facebookF,
                        iconColor: const Color(0xFF1877F2),
                        backgroundColor: Colors.white,
                        onPressed: null,
                        isLoading: false,
                      ),
                      const SizedBox(width: 16),
                      _buildSocialLoginCircleButton(
                        icon: FontAwesomeIcons.xTwitter,
                        iconColor: Colors.black,
                        backgroundColor: Colors.white,
                        onPressed: null,
                        isLoading: false,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Nút mạng xã hội dạng tròn - đồng bộ với WelcomeScreen
  Widget _buildSocialLoginCircleButton({
    required IconData icon,
    required Color iconColor,
    required Color backgroundColor,
    required VoidCallback? onPressed,
    required bool isLoading,
  }) {
    return Container(
      width: 50,
      height: 50,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(25),
          child: Center(
            child: isLoading
                ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
              ),
            )
                : FaIcon(icon, color: iconColor, size: 20),
          ),
        ),
      ),
    );
  }
}