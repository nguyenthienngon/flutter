import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'login_screen.dart';
import 'register_screen.dart';
import 'home_screen.dart';
import 'config.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  _WelcomeScreenState createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> with SingleTickerProviderStateMixin {
  bool _isGoogleLoading = false;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    // Thêm animation cho logo
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
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
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _googleSignIn() async {
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(data['error'] ?? 'Đăng nhập Google thất bại')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi: $e')),
        );
      }
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

    // Bảng màu mới chuyên nghiệp hơn
    final Color primaryColor = Color(0xFF0078D7);      // Microsoft Blue - chuyên nghiệp hơn
    final Color secondaryColor = Color(0xFF50E3C2);    // Mint - tươi mát, phù hợp với tủ lạnh
    final Color accentColor = Color(0xFF00B294);       // Teal - màu tủ lạnh mới
    final Color backgroundColor = Colors.white;
    final Color textDarkColor = Color(0xFF202124);
    final Color textLightColor = Color(0xFF5F6368);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE6F7FF), Colors.white],  // Gradient nhẹ nhàng hơn
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isSmallScreen ? 16.0 : 24.0,
              vertical: 24.0,
            ),
            child: Column(
              children: [
                const Spacer(flex: 1),

                // Logo và tên app với animation - đặt cạnh nhau theo chiều ngang
                FadeTransition(
                  opacity: _fadeAnimation,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Icon tủ lạnh với màu mới đẹp hơn
                      Container(
                        padding: EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            colors: [accentColor, primaryColor],
                            radius: 0.8,
                          ),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: accentColor.withOpacity(0.3),
                              blurRadius: 12,
                              offset: Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.kitchen,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),

                      const SizedBox(width: 16),

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
                            fontSize: isSmallScreen ? 40 : 48,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Text chào mừng
                Text(
                  'Quản lý tủ lạnh thông minh của bạn ngay hôm nay.',
                  style: TextStyle(
                    fontSize: isSmallScreen ? 14 : 16,
                    color: textLightColor,
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),

                const Spacer(flex: 1),

                // Nút Đăng nhập bằng tài khoản
                Container(
                  width: double.infinity,
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
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const LoginScreen()),
                      );
                    },
                    icon: Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: Icon(Icons.login, color: Colors.white, size: 20),
                    ),
                    label: Text(
                      'Đăng nhập bằng tài khoản',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Nút Đăng ký tài khoản mới
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: primaryColor.withOpacity(0.5)),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.05),
                        blurRadius: 8,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton.icon(
                    onPressed: () {
                      // Chuyển đến trang đăng ký
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const RegisterScreen()),
                      );
                    },
                    icon: Padding(
                      padding: const EdgeInsets.only(right: 12.0),
                      child: Icon(Icons.person_add, color: primaryColor, size: 20),
                    ),
                    label: Text(
                      'Đăng ký tài khoản mới',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 16.0),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Separator
                Row(
                  children: [
                    Expanded(child: Divider(color: Colors.grey.shade300, thickness: 1)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Text(
                        'Hoặc tiếp tục với',
                        style: TextStyle(color: textLightColor, fontSize: 14),
                      ),
                    ),
                    Expanded(child: Divider(color: Colors.grey.shade300, thickness: 1)),
                  ],
                ),

                const SizedBox(height: 24),

                // Social Login Buttons in a Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildSocialLoginCircleButton(
                      icon: FontAwesomeIcons.google,
                      iconColor: const Color(0xFFDB4437),
                      backgroundColor: Colors.white,
                      onPressed: _isGoogleLoading ? null : _googleSignIn,
                      isLoading: _isGoogleLoading,
                    ),
                    _buildSocialLoginCircleButton(
                      icon: FontAwesomeIcons.facebookF,
                      iconColor: const Color(0xFF1877F2),
                      backgroundColor: Colors.white,
                      onPressed: null,
                      isLoading: false,
                    ),
                    _buildSocialLoginCircleButton(
                      icon: FontAwesomeIcons.xTwitter,
                      iconColor: Colors.black,
                      backgroundColor: Colors.white,
                      onPressed: null,
                      isLoading: false,
                    ),
                  ],
                ),

                const Spacer(flex: 1),

                // Footer text
                Text(
                  '© 2023 SmartFri. Bảo lưu mọi quyền Nguyễn Thiện Ngôn.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Nút mạng xã hội dạng tròn - trông chuyên nghiệp hơn
  Widget _buildSocialLoginCircleButton({
    required IconData icon,
    required Color iconColor,
    required Color backgroundColor,
    required VoidCallback? onPressed,
    required bool isLoading,
  }) {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(30),
          child: Center(
            child: isLoading
                ? SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.grey),
              ),
            )
                : FaIcon(icon, color: iconColor, size: 24),
          ),
        ),
      ),
    );
  }
}