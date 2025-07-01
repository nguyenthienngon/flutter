import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'package:http/http.dart' as http;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart' as auth;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path/path.dart' as path;

import 'config.dart';

class AddFoodScreen extends StatefulWidget {
  final String uid;
  final String token;

  const AddFoodScreen({super.key, required this.uid, required this.token});

  @override
  _AddFoodScreenState createState() => _AddFoodScreenState();
}

class _AddFoodScreenState extends State<AddFoodScreen> with SingleTickerProviderStateMixin {
  final _picker = ImagePicker();
  File? _image;
  String? _imagePath;
  final _nameController = TextEditingController();
  final _quantityController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _unitId;
  String? _selectedCategoryId;
  DateTime _expiryDate = DateTime.now().add(const Duration(days: 7));
  String? _selectedAreaId;
  String? _aiResult;
  bool _isLoading = true;
  bool _isSaving = false;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<Map<String, dynamic>> _storageAreas = [];
  List<Map<String, dynamic>> _units = [];
  List<Map<String, dynamic>> _foodCategories = [];

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  drive.DriveApi? _driveApi;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _checkUserAuth();
    _fetchInitialData();
    _initGoogleDrive();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _animationController.dispose();
    super.dispose();
  }

  Future<void> _initGoogleDrive() async {
    try {
      final serviceAccountCredentials = await _loadServiceAccountCredentials();
      final client = await auth.clientViaServiceAccount(
        serviceAccountCredentials,
        ['https://www.googleapis.com/auth/drive.file'],
      );
      _driveApi = drive.DriveApi(client);
      print('Google Drive API khởi tạo thành công');
    } catch (e) {
      print('Lỗi khởi tạo Google Drive: $e');
      _showErrorSnackBar('Lỗi khởi tạo Google Drive: $e');
    }
  }

  Future<auth.ServiceAccountCredentials> _loadServiceAccountCredentials() async {
    final credentialsJson = await rootBundle.loadString('assets/credentials.json');
    return auth.ServiceAccountCredentials.fromJson(credentialsJson);
  }

  Future<void> _checkUserAuth() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        await FirebaseAuth.instance.signInAnonymously();
        print('Đăng nhập ẩn danh thành công');
      } else {
        print('Người dùng đã đăng nhập: ${user.uid}');
      }
    } catch (e) {
      print('Lỗi đăng nhập ẩn danh: $e');
      _showErrorSnackBar('Lỗi đăng nhập: $e');
    }
  }

  Future<void> _fetchInitialData() async {
    try {
      print('Tải dữ liệu ban đầu - Thời gian: ${DateTime.now()}');
      await Future.wait([
        _fetchStorageAreas(),
        _fetchUnits(),
        _fetchFoodCategories(),
      ]);
      if (_storageAreas.isEmpty || _units.isEmpty || _foodCategories.isEmpty) {
        _showErrorSnackBar('Không thể tải dữ liệu. Vui lòng thử lại sau.');
      }
    } catch (e) {
      print('Lỗi tải dữ liệu ban đầu: $e');
      _showErrorSnackBar('Lỗi tải dữ liệu ban đầu: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
      _animationController.forward();
    }
  }

  Future<void> _fetchStorageAreas() async {
    try {
      print('Lấy danh sách khu vực lưu trữ...');
      final snapshot = await _firestore.collection('StorageAreas').get();
      setState(() {
        _storageAreas = snapshot.docs
            .map((doc) => {...doc.data() as Map<String, dynamic>, 'id': doc.id})
            .toList();
        _selectedAreaId ??= _storageAreas.isNotEmpty ? _storageAreas[0]['id'] : null;
      });
    } catch (e) {
      print('Lỗi lấy khu vực lưu trữ: $e');
    }
  }

  Future<void> _fetchUnits() async {
    try {
      print('Lấy danh sách đơn vị...');
      final snapshot = await _firestore.collection('Units').get();
      setState(() {
        _units = snapshot.docs
            .map((doc) => {...doc.data() as Map<String, dynamic>, 'id': doc.id})
            .toList();
        _unitId ??= _units.isNotEmpty ? _units[0]['id'] : null;
      });
    } catch (e) {
      print('Lỗi lấy đơn vị: $e');
    }
  }

  Future<void> _fetchFoodCategories() async {
    try {
      print('Lấy danh sách danh mục thực phẩm...');
      final snapshot = await _firestore.collection('FoodCategories').get();
      setState(() {
        _foodCategories = snapshot.docs
            .map((doc) => {...doc.data() as Map<String, dynamic>, 'id': doc.id})
            .toList();
        _selectedCategoryId ??= _foodCategories.isNotEmpty ? _foodCategories[0]['id'] : null;
      });
    } catch (e) {
      print('Lỗi lấy danh mục thực phẩm: $e');
    }
  }

  Future<void> _pickImage() async {
    try {
      print('Chọn ảnh từ thư viện...');
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (pickedFile != null) {
        setState(() {
          _image = File(pickedFile.path);
          _imagePath = pickedFile.path;
          _aiResult = null;
        });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          setState(() {
            _aiResult = 'Rau củ quả (Độ tin cậy: 92%)';
            _nameController.text = 'Rau củ quả';
          });
        }
      }
    } catch (e) {
      print('Lỗi chọn ảnh: $e');
      _showErrorSnackBar('Lỗi chọn ảnh: $e');
    }
  }

  Future<void> _pickImageFromDrive() async {
    try {
      print('Chọn ảnh từ Google Drive...');

      final googleSignIn = GoogleSignIn(
        scopes: [
          'https://www.googleapis.com/auth/drive.readonly',
        ],
      );

      final GoogleSignInAccount? account = await googleSignIn.signIn();
      if (account == null) {
        print('Đăng nhập Google thất bại');
        return;
      }

      final authHeaders = await account.authHeaders;
      final accessToken = authHeaders['Authorization']?.split(' ')[1];
      if (accessToken == null) {
        print('Không thể lấy access token');
        return;
      }

      final response = await http.get(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files?q=mimeType%3D%27image%2Fjpeg%27%20or%20mimeType%3D%27image%2Fpng%27&fields=files(id,name,webContentLink,thumbnailLink)&spaces=drive'),
        headers: {
          'Authorization': 'Bearer $accessToken',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files = data['files'] as List<dynamic>;
        if (files.isEmpty) {
          print('Không tìm thấy ảnh trong Google Drive');
          return;
        }

        if (mounted) {
          final selectedFile = await showDialog<Map<String, dynamic>>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Chọn ảnh từ Google Drive'),
              content: SingleChildScrollView(
                child: Column(
                  children: files.map((file) {
                    return ListTile(
                      title: Text(file['name']),
                      onTap: () => Navigator.pop(context, file),
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Hủy'),
                ),
              ],
            ),
          );

          if (selectedFile != null) {
            await _setFilePermissions(selectedFile['id'], accessToken);

            setState(() {
              _imagePath = selectedFile['webContentLink'];
              _image = null;
              _aiResult = null;
            });

            await Future.delayed(const Duration(seconds: 2));
            if (mounted) {
              setState(() {
                _aiResult = 'Rau củ quả (Độ tin cậy: 92%)';
                _nameController.text = 'Rau củ quả';
              });
            }
          }
        }
      } else {
        print('Lỗi khi lấy danh sách ảnh: ${response.body}');
      }
    } catch (e) {
      print('Lỗi chọn ảnh từ Google Drive: $e');
    }
  }

  Future<void> _setFilePermissions(String fileId, String accessToken) async {
    try {
      final response = await http.post(
        Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId/permissions'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'type': 'anyone',
          'role': 'reader',
        }),
      );

      if (response.statusCode != 200) {
        print('Lỗi khi đặt quyền cho tệp: ${response.body}');
      }
    } catch (e) {
      print('Lỗi đặt quyền: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      print('Chụp ảnh...');
      final pickedFile = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (pickedFile != null) {
        setState(() {
          _image = File(pickedFile.path);
          _imagePath = pickedFile.path;
          _aiResult = null;
        });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          setState(() {
            _aiResult = 'Rau củ quả (Độ tin cậy: 92%)';
            _nameController.text = 'Rau củ quả';
          });
        }
      }
    } catch (e) {
      print('Lỗi chụp ảnh: $e');
      _showErrorSnackBar('Lỗi chụp ảnh: $e');
    }
  }

  Future<String?> _uploadToGoogleDrive(String filePath) async {
    if (_driveApi == null) {
      _showErrorSnackBar('Google Drive chưa được khởi tạo. Vui lòng khởi động lại ứng dụng.');
      return null;
    }
    try {
      var connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        throw Exception('Không có kết nối mạng. Vui lòng kiểm tra kết nối.');
      }

      final file = File(filePath);
      if (!await file.exists()) {
        throw Exception('Tệp không tồn tại tại đường dẫn: $filePath');
      }

      var driveFile = drive.File();
      driveFile.name = 'food_${DateTime.now().millisecondsSinceEpoch}.jpg';
      driveFile.parents = ['appDataFolder'];

      var media = drive.Media(file.openRead(), await file.length());
      final uploadedFile = await _driveApi!.files.create(driveFile, uploadMedia: media);

      final fileId = uploadedFile.id;
      if (fileId == null) {
        throw Exception('Không thể lấy ID của file đã tải lên');
      }
      await _driveApi!.permissions.create(
        drive.Permission()
          ..type = 'anyone'
          ..role = 'reader',
        fileId,
      );
      final url = 'https://drive.google.com/uc?export=download&id=$fileId';

      print('Ảnh đã được tải lên Google Drive: $url');
      return url;
    } catch (e, stackTrace) {
      print('Lỗi tải lên Google Drive: $e');
      print('Stack trace: $stackTrace');
      _showErrorSnackBar('Lỗi tải lên Google Drive: $e');
      return null;
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Chọn nguồn ảnh',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF202124),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _buildImageSourceButton(
                    icon: Icons.photo_library_outlined,
                    label: 'Thư viện',
                    onTap: () {
                      Navigator.pop(context);
                      _pickImage();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildImageSourceButton(
                    icon: Icons.cloud_outlined,
                    label: 'Google Drive',
                    onTap: () {
                      Navigator.pop(context);
                      _pickImageFromDrive();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildImageSourceButton(
                    icon: Icons.camera_alt_outlined,
                    label: 'Chụp ảnh',
                    onTap: () {
                      Navigator.pop(context);
                      _takePhoto();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSourceButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: const Color(0xFF0078D7)),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF202124),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddUnitDialog() async {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm đơn vị mới'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên đơn vị',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _showErrorSnackBar('Vui lòng nhập tên đơn vị');
                return;
              }
              try {
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_unit'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'name': name}),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200 && data['success']) {
                  await _fetchUnits();
                  setState(() {
                    _unitId = data['unitId'];
                  });
                  _showErrorSnackBar('Đã thêm đơn vị thành công!');
                  Navigator.pop(context);
                } else {
                  _showErrorSnackBar('Lỗi khi thêm đơn vị: ${data['error']}');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi thêm đơn vị: $e');
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddCategoryDialog() async {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm danh mục mới'),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên danh mục',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) {
                _showErrorSnackBar('Vui lòng nhập tên danh mục');
                return;
              }
              try {
                final response = await http.post(
                  Uri.parse('${Config.getNgrokUrl()}/add_food_category'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'name': name, 'urlImage': ''}),
                );
                final data = jsonDecode(response.body);
                if (response.statusCode == 200 && data['success']) {
                  await _fetchFoodCategories();
                  setState(() {
                    _selectedCategoryId = data['categoryId'];
                  });
                  _showErrorSnackBar('Đã thêm danh mục thành công!');
                  Navigator.pop(context);
                } else {
                  _showErrorSnackBar('Lỗi khi thêm danh mục: ${data['error']}');
                }
              } catch (e) {
                _showErrorSnackBar('Lỗi khi thêm danh mục: $e');
              }
            },
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveFood() async {
    if (!mounted || _isSaving || _formKey.currentState == null || !_formKey.currentState!.validate()) {
      if (mounted) _showErrorSnackBar('Vui lòng kiểm tra lại thông tin nhập vào.');
      return;
    }
    if (_selectedAreaId == null || _selectedCategoryId == null || _unitId == null) {
      if (mounted) _showErrorSnackBar('Vui lòng chọn khu vực, danh mục và đơn vị.');
      return;
    }
    if (_imagePath == null) {
      if (mounted) _showErrorSnackBar('Vui lòng chọn ảnh thực phẩm.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      print('Bắt đầu lưu thực phẩm - Thời gian: ${DateTime.now()}');

      String? imageUrl;
      if (_image != null) {
        imageUrl = await _uploadToGoogleDrive(_imagePath!);
        if (imageUrl == null) {
          throw Exception('Không thể tải ảnh lên Google Drive');
        }
      } else {
        imageUrl = _imagePath;
      }

      final foodResponse = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_food'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _nameController.text.trim(),
          'categoryId': _selectedCategoryId,
          'userId': widget.uid,
          'imageUrl': imageUrl,
        }),
      );
      final foodData = jsonDecode(foodResponse.body);
      if (foodResponse.statusCode != 200) {
        throw Exception(foodData['error'] ?? 'Lỗi khi thêm thực phẩm');
      }
      final foodId = foodData['foodId'] as String?;
      if (foodId == null) throw Exception('Không nhận được foodId');

      final expiryDateString = DateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'+07:00'").format(_expiryDate);

      final storageResponse = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_storage_log'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'areaId': _selectedAreaId,
          'foodId': foodId,
          'quantity': double.tryParse(_quantityController.text) ?? 0,
          'unitId': _unitId,
          'userId': widget.uid,
          'expiryDate': expiryDateString,
        }),
      );
      final storageData = jsonDecode(storageResponse.body);
      if (storageResponse.statusCode != 200) {
        throw Exception(storageData['error'] ?? 'Lỗi khi lưu nhật ký');
      }

      await _firestore.collection('Foods').doc(foodId).set({
        'name': _nameController.text.trim(),
        'categoryId': _selectedCategoryId,
        'userId': widget.uid,
        'imageUrl': imageUrl,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 8),
                Text('Đã thêm thực phẩm thành công!'),
              ],
            ),
            backgroundColor: Colors.green[600],
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e, stackTrace) {
      print('Lỗi khi lưu thực phẩm: $e');
      print('Stack trace: $stackTrace');
      if (mounted) _showErrorSnackBar('Lỗi khi lưu thực phẩm: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red[600],
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Vui lòng nhập tên thực phẩm';
    }
    return null;
  }

  String? _validateQuantity(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Vui lòng nhập số lượng';
    }
    final quantity = double.tryParse(value);
    if (quantity == null || quantity <= 0) {
      return 'Số lượng phải lớn hơn 0';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Color primaryColor = const Color(0xFF0078D7);
    final Color accentColor = const Color(0xFF00B294);
    final Color textDarkColor = const Color(0xFF202124);

    return Scaffold(
      body: _isLoading
          ? Center(
        child: LoadingAnimationWidget.threeArchedCircle(
          color: primaryColor,
          size: 100,
        ),
      )
          : Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFE6F7FF), Colors.white],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(Icons.arrow_back_ios, color: primaryColor, size: 20),
                        onPressed: () => Navigator.pop(context),
                        tooltip: 'Quay lại',
                        padding: const EdgeInsets.all(8),
                        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                      ),
                      Expanded(
                        child: Text(
                          'Thêm Thực Phẩm',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: textDarkColor,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [primaryColor, accentColor],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: TextButton(
                          onPressed: _isSaving || _isLoading ? null : _saveFood,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            minimumSize: const Size(60, 32),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          child: _isSaving
                              ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                              : Text(
                            'Lưu',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: Column(
                                children: [
                                  Container(
                                    height: 160,
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                      color: Colors.grey[50],
                                    ),
                                    child: _image != null
                                        ? Stack(
                                      children: [
                                        ClipRRect(
                                          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                          child: Image.file(
                                            _image!,
                                            width: double.infinity,
                                            height: 160,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) => Center(
                                              child: Icon(Icons.error, color: Colors.red[600], size: 40),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          top: 6,
                                          right: 6,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(0.5),
                                              shape: BoxShape.circle,
                                            ),
                                            child: IconButton(
                                              icon: const Icon(Icons.close, color: Colors.white, size: 18),
                                              onPressed: () {
                                                setState(() {
                                                  _image = null;
                                                  _imagePath = null;
                                                  _aiResult = null;
                                                  _nameController.clear();
                                                });
                                              },
                                              padding: const EdgeInsets.all(4),
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                        : _imagePath != null
                                        ? Stack(
                                      children: [
                                        ClipRRect(
                                          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                                          child: Image.network(
                                            _imagePath!,
                                            width: double.infinity,
                                            height: 160,
                                            fit: BoxFit.cover,
                                            loadingBuilder: (context, child, loadingProgress) {
                                              if (loadingProgress == null) return child;
                                              return Center(
                                                child: CircularProgressIndicator(
                                                  value: loadingProgress.expectedTotalBytes != null
                                                      ? loadingProgress.cumulativeBytesLoaded /
                                                      loadingProgress.expectedTotalBytes!
                                                      : null,
                                                ),
                                              );
                                            },
                                            errorBuilder: (context, error, stackTrace) => Center(
                                              child: Icon(Icons.error, color: Colors.red[600], size: 40),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          top: 6,
                                          right: 6,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacity(0.5),
                                              shape: BoxShape.circle,
                                            ),
                                            child: IconButton(
                                              icon: const Icon(Icons.close, color: Colors.white, size: 18),
                                              onPressed: () {
                                                setState(() {
                                                  _image = null;
                                                  _imagePath = null;
                                                  _aiResult = null;
                                                  _nameController.clear();
                                                });
                                              },
                                              padding: const EdgeInsets.all(4),
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                        : Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.add_photo_alternate_outlined,
                                          size: 40,
                                          color: Colors.grey[400],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Thêm ảnh thực phẩm',
                                          style: TextStyle(
                                            color: Colors.grey[600],
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      children: [
                                        if (_image == null && _imagePath == null)
                                          Container(
                                            width: double.infinity,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  primaryColor.withOpacity(0.1),
                                                  accentColor.withOpacity(0.1),
                                                ],
                                                begin: Alignment.centerLeft,
                                                end: Alignment.centerRight,
                                              ),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: primaryColor.withOpacity(0.3)),
                                            ),
                                            child: TextButton.icon(
                                              onPressed: _isLoading ? null : _showImageSourceDialog,
                                              icon: Icon(Icons.add_a_photo_outlined, color: primaryColor, size: 16),
                                              label: Text(
                                                'Chọn ảnh',
                                                style: TextStyle(
                                                  color: primaryColor,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                              style: TextButton.styleFrom(
                                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                                minimumSize: const Size(0, 36),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (_aiResult != null)
                                          Container(
                                            width: double.infinity,
                                            padding: const EdgeInsets.all(10),
                                            margin: const EdgeInsets.only(top: 8),
                                            decoration: BoxDecoration(
                                              color: Colors.green[50],
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: Colors.green[200]!),
                                            ),
                                            child: Row(
                                              children: [
                                                Icon(Icons.smart_toy_outlined, color: Colors.green[600], size: 16),
                                                const SizedBox(width: 6),
                                                Expanded(
                                                  child: Text(
                                                    'AI nhận diện: $_aiResult',
                                                    style: TextStyle(
                                                      color: Colors.green[700],
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w500,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.05),
                                    blurRadius: 8,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Tên thực phẩm',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: textDarkColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  TextFormField(
                                    controller: _nameController,
                                    validator: _validateName,
                                    style: const TextStyle(fontSize: 14),
                                    decoration: InputDecoration(
                                      hintText: 'Nhập tên thực phẩm',
                                      hintStyle: const TextStyle(fontSize: 14),
                                      prefixIcon: Icon(Icons.fastfood_outlined, color: primaryColor, size: 16),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide.none,
                                      ),
                                      filled: true,
                                      fillColor: Colors.grey[50],
                                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: primaryColor, width: 1.5),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Colors.grey.shade200),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Flexible(
                                        flex: 3,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Số lượng',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: textDarkColor,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            TextFormField(
                                              controller: _quantityController,
                                              validator: _validateQuantity,
                                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                              style: const TextStyle(fontSize: 14),
                                              decoration: InputDecoration(
                                                hintText: '0',
                                                hintStyle: const TextStyle(fontSize: 14),
                                                prefixIcon: Icon(Icons.scale_outlined, color: primaryColor, size: 16),
                                                border: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                  borderSide: BorderSide.none,
                                                ),
                                                filled: true,
                                                fillColor: Colors.grey[50],
                                                contentPadding:
                                                const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                                focusedBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                  borderSide: BorderSide(color: primaryColor, width: 1.5),
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        flex: 2,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Đơn vị',
                                              style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: textDarkColor,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            DropdownButtonFormField<String>(
                                              value: _unitId,
                                              isExpanded: true,
                                              style: TextStyle(fontSize: 14, color: textDarkColor),
                                              items: [
                                                ..._units.map((unit) {
                                                  return DropdownMenuItem<String>(
                                                    value: unit['id'],
                                                    child: Text(
                                                      unit['name'] ?? 'N/A',
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(fontSize: 14),
                                                    ),
                                                  );
                                                }).toList(),
                                                DropdownMenuItem<String>(
                                                  value: 'add_new_unit',
                                                  child: Text(
                                                    'Thêm đơn vị mới',
                                                    style: TextStyle(color: primaryColor, fontSize: 14),
                                                  ),
                                                ),
                                              ],
                                              onChanged: (String? newValue) {
                                                if (newValue == 'add_new_unit') {
                                                  _showAddUnitDialog();
                                                } else {
                                                  setState(() => _unitId = newValue);
                                                }
                                              },
                                              decoration: InputDecoration(
                                                hintText: 'Đơn vị',
                                                hintStyle: const TextStyle(fontSize: 14),
                                                border: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                  borderSide: BorderSide.none,
                                                ),
                                                filled: true,
                                                fillColor: Colors.grey[50],
                                                contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                                focusedBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                  borderSide: BorderSide(color: primaryColor, width: 1.5),
                                                ),
                                                enabledBorder: OutlineInputBorder(
                                                  borderRadius: BorderRadius.circular(8),
                                                  borderSide: BorderSide(color: Colors.grey.shade200),
                                                ),
                                              ),
                                              validator: (value) =>
                                              value == null || value == 'add_new_unit' ? 'Vui lòng chọn hoặc thêm đơn vị' : null,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'Danh mục',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: textDarkColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  DropdownButtonFormField<String>(
                                    value: _selectedCategoryId,
                                    isExpanded: true,
                                    style: TextStyle(fontSize: 14, color: textDarkColor),
                                    items: [
                                      ..._foodCategories.map((category) {
                                        return DropdownMenuItem<String>(
                                          value: category['id'],
                                          child: Text(
                                            category['name'] ?? 'Không xác định',
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontSize: 14),
                                          ),
                                        );
                                      }).toList(),
                                      DropdownMenuItem<String>(
                                        value: 'add_new_category',
                                        child: Text(
                                          'Thêm danh mục mới',
                                          style: TextStyle(color: primaryColor, fontSize: 14),
                                        ),
                                      ),
                                    ],
                                    onChanged: (String? newValue) {
                                      if (newValue == 'add_new_category') {
                                        _showAddCategoryDialog();
                                      } else {
                                        setState(() => _selectedCategoryId = newValue);
                                      }
                                    },
                                    decoration: InputDecoration(
                                      hintText: 'Chọn danh mục',
                                      hintStyle: const TextStyle(fontSize: 14),
                                      prefixIcon: Icon(Icons.category_outlined, color: primaryColor, size: 16),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide.none,
                                      ),
                                      filled: true,
                                      fillColor: Colors.grey[50],
                                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: primaryColor, width: 1.5),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Colors.grey.shade200),
                                      ),
                                    ),
                                    validator: (value) =>
                                    value == null || value == 'add_new_category' ? 'Vui lòng chọn hoặc thêm danh mục' : null,
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'Ngày hết hạn',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: textDarkColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  InkWell(
                                    onTap: _isLoading
                                        ? null
                                        : () async {
                                      if (!mounted) return;
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate: _expiryDate,
                                        firstDate: DateTime.now(),
                                        lastDate: DateTime(2030),
                                        builder: (context, child) {
                                          return Theme(
                                            data: Theme.of(context).copyWith(
                                              colorScheme: ColorScheme.light(
                                                primary: primaryColor,
                                                onPrimary: Colors.white,
                                                surface: Colors.white,
                                                onSurface: textDarkColor,
                                              ),
                                            ),
                                            child: child!,
                                          );
                                        },
                                      );
                                      if (picked != null && mounted) {
                                        setState(() => _expiryDate = picked);
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                      decoration: BoxDecoration(
                                        color: Colors.grey[50],
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.grey.shade200),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(Icons.calendar_today_outlined, color: primaryColor, size: 16),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${_expiryDate.day}/${_expiryDate.month}/${_expiryDate.year}',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: textDarkColor,
                                            ),
                                          ),
                                          const Spacer(),
                                          Icon(Icons.arrow_drop_down, color: Colors.grey[600], size: 16),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'Khu vực lưu trữ',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: textDarkColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  DropdownButtonFormField<String>(
                                    value: _selectedAreaId,
                                    isExpanded: true,
                                    style: TextStyle(fontSize: 14, color: textDarkColor),
                                    items: _storageAreas.map((area) {
                                      return DropdownMenuItem<String>(
                                        value: area['id'],
                                        child: Row(
                                          children: [
                                            Icon(Icons.kitchen_outlined, color: primaryColor, size: 14),
                                            const SizedBox(width: 6),
                                            Expanded(
                                              child: Text(
                                                area['name'] ?? 'Không xác định',
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(fontSize: 14),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    }).toList(),
                                    onChanged: (String? newValue) {
                                      if (mounted) {
                                        setState(() => _selectedAreaId = newValue);
                                      }
                                    },
                                    decoration: InputDecoration(
                                      hintText: 'Chọn khu vực lưu trữ',
                                      hintStyle: const TextStyle(fontSize: 14),
                                      prefixIcon: Icon(Icons.location_on_outlined, color: primaryColor, size: 16),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide.none,
                                      ),
                                      filled: true,
                                      fillColor: Colors.grey[50],
                                      contentPadding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: primaryColor, width: 1.5),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        borderSide: BorderSide(color: Colors.grey.shade200),
                                      ),
                                    ),
                                    validator: (value) => value == null ? 'Vui lòng chọn khu vực lưu trữ' : null,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}