import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dropdown_button2/dropdown_button2.dart';
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
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'config.dart';

class AddFoodScreen extends StatefulWidget {
  final String uid;
  final String token;
  final bool isDarkMode;

  const AddFoodScreen({
    super.key,
    required this.uid,
    required this.token,
    required this.isDarkMode,
  });

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
  Interpreter? _interpreter; // Biến lưu trữ mô hình TFLite
  List<String>? _labels; // Danh sách nhãn

  // Modern color scheme
  final Color primaryColor = const Color(0xFF0078D7);
  final Color accentColor = const Color(0xFF00B294);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color errorColor = const Color(0xFFE74C3C);
  final Color backgroundColor = const Color(0xFFE6F7FF);
  final Color surfaceColor = Colors.white;
  final Color textPrimaryColor = const Color(0xFF202124);
  final Color textSecondaryColor = const Color(0xFF5F6368);

  // Dynamic colors based on dark mode
  Color get currentBackgroundColor => widget.isDarkMode ? const Color(0xFF121212) : backgroundColor;
  Color get currentSurfaceColor => widget.isDarkMode ? const Color(0xFF1E1E1E) : surfaceColor;
  Color get currentTextPrimaryColor => widget.isDarkMode ? const Color(0xFFE0E0E0) : textPrimaryColor;
  Color get currentTextSecondaryColor => widget.isDarkMode ? const Color(0xFFB0B0B0) : textSecondaryColor;

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
    _loadModel(); // Tải mô hình TFLite
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _animationController.dispose();
    _interpreter?.close(); // Giải phóng mô hình TFLite
    super.dispose();
  }

  // Tải mô hình TFLite và nhãn
  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model.tflite');
      final labelsData = await DefaultAssetBundle.of(context).loadString('assets/labels.txt');
      _labels = labelsData.split('\n').where((line) => line.isNotEmpty).toList();
      print('Mô hình và nhãn đã được tải thành công');
    } catch (e) {
      _showErrorSnackBar('Lỗi tải mô hình TFLite: $e');
    }
  }

  // Hàm xử lý hình ảnh và chạy suy luận
  Future<String?> _runInference(String imagePath) async {
    if (_interpreter == null || _labels == null) {
      _showErrorSnackBar('Mô hình TFLite chưa được tải');
      return null;
    }

    try {
      final imageFile = File(imagePath);
      final imageBytes = await imageFile.readAsBytes();
      img.Image? image = img.decodeImage(imageBytes);
      if (image == null) {
        _showErrorSnackBar('Không thể giải mã hình ảnh');
        return null;
      }

      // Thay đổi kích thước hình ảnh (giả sử mô hình yêu cầu 224x224)
      image = img.copyResize(image, width: 224, height: 224);

      // Lấy dữ liệu pixel ở định dạng RGBA
      final input = image.getBytes(); // Mặc định trả về RGBA

      // Chuyển đổi từ RGBA sang RGB (loại bỏ kênh alpha)
      final rgbInput = Float32List(224 * 224 * 3);
      for (int i = 0, j = 0; i < input.length; i += 4, j += 3) {
        rgbInput[j] = input[i] / 255.0;     // R
        rgbInput[j + 1] = input[i + 1] / 255.0; // G
        rgbInput[j + 2] = input[i + 2] / 255.0; // B
      }

      // Định dạng đầu vào cho mô hình
      final inputShape = _interpreter!.getInputTensor(0).shape;
      final inputData = rgbInput.reshape(inputShape);

      // Định dạng đầu ra
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final output = List.filled(outputShape.reduce((a, b) => a * b), 0.0).reshape(outputShape);

      // Chạy suy luận
      _interpreter!.run(inputData, output);

      // Xử lý đầu ra
      final outputList = (output as List<dynamic>).cast<double>();
      final maxIndex = outputList.indexOf(outputList.reduce((a, b) => a > b ? a : b));
      final confidence = outputList[maxIndex];
      final label = _labels![maxIndex];

      return '$label (Độ tin cậy: ${(confidence * 100).toStringAsFixed(2)}%)';
    } catch (e) {
      _showErrorSnackBar('Lỗi nhận diện hình ảnh: $e');
      return null;
    }
  }

  // Tải hình ảnh từ URL (cho Google Drive)
  Future<String?> _downloadImageFromUrl(String url) async {
    try {
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final tempDir = await getTemporaryDirectory();
        final tempFile = File('${tempDir.path}/temp_image.jpg');
        await tempFile.writeAsBytes(response.bodyBytes);
        return tempFile.path;
      } else {
        throw Exception('Không thể tải hình ảnh từ Google Drive');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi tải hình ảnh từ URL: $e');
      return null;
    }
  }

  Future<void> _initGoogleDrive() async {
    final serviceAccountCredentials = await _loadServiceAccountCredentials();
    final client = await auth.clientViaServiceAccount(
      serviceAccountCredentials,
      ['https://www.googleapis.com/auth/drive.file'],
    );
    _driveApi = drive.DriveApi(client);
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
      } else {
        print('Người dùng đã đăng nhập: ${user.uid}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi đăng nhập: $e');
    }
  }

  Future<void> _fetchInitialData() async {
    try {
      await Future.wait([
        _fetchStorageAreas(),
        _fetchUnits(),
        _fetchFoodCategories(),
      ]);
      if (_storageAreas.isEmpty || _units.isEmpty || _foodCategories.isEmpty) {
        _showErrorSnackBar('Không thể tải dữ liệu. Vui lòng thử lại sau.');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi tải dữ liệu ban đầu: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
      _animationController.forward();
    }
  }

  Future<void> _fetchStorageAreas() async {
    try {
      final snapshot = await _firestore.collection('StorageAreas').get();
      setState(() {
        _storageAreas = snapshot.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList();
        _selectedAreaId ??= _storageAreas.isNotEmpty ? _storageAreas[0]['id'] : null;
      });
    } catch (e) {}
  }

  Future<void> _fetchUnits() async {
    try {
      final snapshot = await _firestore.collection('Units').get();
      setState(() {
        _units = snapshot.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList();
        _unitId ??= _units.isNotEmpty ? _units[0]['id'] : null;
      });
    } catch (e) {}
  }

  Future<void> _fetchFoodCategories() async {
    try {
      final snapshot = await _firestore.collection('FoodCategories').get();
      setState(() {
        _foodCategories = snapshot.docs
            .map((doc) => {...doc.data(), 'id': doc.id})
            .toList();
        _selectedCategoryId ??= _foodCategories.isNotEmpty ? _foodCategories[0]['id'] : null;
      });
    } catch (e) {}
  }

  Future<void> _pickImage() async {
    try {
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
        final result = await _runInference(pickedFile.path);
        if (mounted && result != null) {
          setState(() {
            _aiResult = result;
            _nameController.text = result.split(' (')[0];
          });
        }
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi chọn ảnh: $e');
    }
  }

  Future<void> _pickImageFromDrive() async {
    try {
      final googleSignIn = GoogleSignIn(
        scopes: ['https://www.googleapis.com/auth/drive.readonly'],
      );
      final GoogleSignInAccount? account = await googleSignIn.signIn();
      if (account == null) return;

      final authHeaders = await account.authHeaders;
      final accessToken = authHeaders['Authorization']?.split(' ')[1];
      if (accessToken == null) return;

      final response = await http.get(
        Uri.parse(
            'https://www.googleapis.com/drive/v3/files?q=mimeType%3D%27image%2Fjpeg%27%20or%20mimeType%3D%27image%2Fpng%27&fields=files(id,name,webContentLink,thumbnailLink)&spaces=drive'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final files = data['files'] as List<dynamic>;
        if (files.isEmpty) return;

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
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Hủy'))],
            ),
          );

          if (selectedFile != null) {
            await _setFilePermissions(selectedFile['id'], accessToken);
            final imagePath = await _downloadImageFromUrl(selectedFile['webContentLink']);
            if (imagePath != null) {
              setState(() {
                _imagePath = selectedFile['webContentLink'];
                _image = null;
                _aiResult = null;
              });
              final result = await _runInference(imagePath);
              if (mounted && result != null) {
                setState(() {
                  _aiResult = result;
                  _nameController.text = result.split(' (')[0];
                });
              }
            }
          }
        }
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi chọn ảnh từ Google Drive: $e');
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
        body: jsonEncode({'type': 'anyone', 'role': 'reader'}),
      );
      if (response.statusCode != 200) {}
    } catch (e) {}
  }

  Future<void> _takePhoto() async {
    try {
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
        final result = await _runInference(pickedFile.path);
        if (mounted && result != null) {
          setState(() {
            _aiResult = result;
            _nameController.text = result.split(' (')[0];
          });
        }
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi chụp ảnh: $e');
    }
  }

  Future<String?> _uploadToGoogleDrive(String filePath) async {
    if (_driveApi == null) {
      _showErrorSnackBar('Google Drive chưa được khởi tạo. Sử dụng ảnh cục bộ.');
      return filePath;
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
        drive.Permission()..type = 'anyone'..role = 'reader',
        fileId,
      );

      final url = 'https://drive.google.com/uc?export=download&id=$fileId';
      return url;
    } catch (e) {
      _showErrorSnackBar('Lỗi tải lên Google Drive: $e');
      return null;
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: currentSurfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 5,
              decoration: BoxDecoration(
                color: currentTextSecondaryColor.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Chọn nguồn ảnh',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              alignment: WrapAlignment.center,
              children: [
                _buildModernImageSourceButton(
                  icon: Icons.photo_library_rounded,
                  label: 'Thư viện',
                  color: primaryColor,
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage();
                  },
                ),
                _buildModernImageSourceButton(
                  icon: Icons.cloud_rounded,
                  label: 'Google Drive',
                  color: accentColor,
                  onTap: () {
                    Navigator.pop(context);
                    _pickImageFromDrive();
                  },
                ),
                _buildModernImageSourceButton(
                  icon: Icons.camera_alt_rounded,
                  label: 'Chụp ảnh',
                  color: primaryColor,
                  onTap: () {
                    Navigator.pop(context);
                    _takePhoto();
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildModernImageSourceButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Container(
      width: 100,
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Column(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: color.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(height: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: currentTextPrimaryColor,
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

  Future<void> _showAddUnitDialog() async {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.add_circle_outline, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm đơn vị mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên đơn vị',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
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
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.category_outlined, color: primaryColor),
            const SizedBox(width: 8),
            const Text('Thêm danh mục mới'),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: 'Nhập tên danh mục',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
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
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Lưu', style: TextStyle(color: Colors.white)),
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

    setState(() => _isSaving = true);

    try {
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
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 12),
                const Expanded(child: Text('Đã thêm thực phẩm thành công!')),
              ],
            ),
            backgroundColor: successColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            margin: const EdgeInsets.all(16),
          ),
        );
      }
    } catch (e) {
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
            Icon(Icons.error_outline_rounded, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: errorColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
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
    return Scaffold(
      backgroundColor: currentBackgroundColor,
      body: _isLoading
          ? Container(
        color: currentBackgroundColor,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: currentSurfaceColor,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: LoadingAnimationWidget.threeArchedCircle(
                  color: primaryColor,
                  size: 60,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Đang tải dữ liệu...',
                style: TextStyle(
                  color: currentTextPrimaryColor,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      )
          : SafeArea(
        child: Column(
          children: [
            // Modern Header
            Container(
              margin: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [primaryColor, accentColor],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withOpacity(0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'Thêm Thực Phẩm',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Quản lý thông minh tủ lạnh',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.8),
                            ),
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      height: 48,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.white.withOpacity(0.2), Colors.white.withOpacity(0.1)],
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.save_rounded, color: Colors.white),
                          onPressed: _isSaving || _isLoading ? null : _saveFood,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Content
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildImageSection(),
                        const SizedBox(height: 20),
                        _buildFormSection(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageSection() {
    return Container(
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 200,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
              color: currentBackgroundColor.withOpacity(0.1),
            ),
            child: _image != null
                ? Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Image.file(
                    _image!,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        Center(child: Icon(Icons.error, color: errorColor, size: 40)),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      onPressed: () {
                        setState(() {
                          _image = null;
                          _imagePath = null;
                          _aiResult = null;
                          _nameController.clear();
                        });
                      },
                    ),
                  ),
                ),
              ],
            )
                : _imagePath != null
                ? Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                  child: Image.network(
                    _imagePath!,
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                              loadingProgress.expectedTotalBytes!
                              : null,
                          color: primaryColor,
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) =>
                        Center(child: Icon(Icons.error, color: errorColor, size: 40)),
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white, size: 20),
                      onPressed: () {
                        setState(() {
                          _image = null;
                          _imagePath = null;
                          _aiResult = null;
                          _nameController.clear();
                        });
                      },
                    ),
                  ),
                ),
              ],
            )
                : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [primaryColor.withOpacity(0.1), accentColor.withOpacity(0.1)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Icon(
                    Icons.add_photo_alternate_rounded,
                    size: 40,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Thêm ảnh thực phẩm',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: currentTextPrimaryColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'AI sẽ tự động nhận diện thực phẩm',
                  style: TextStyle(
                    fontSize: 14,
                    color: currentTextSecondaryColor,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                if (_image == null && _imagePath == null)
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryColor, accentColor],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withOpacity(0.3),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: TextButton.icon(
                      onPressed: _isLoading ? null : _showImageSourceDialog,
                      icon: const Icon(Icons.add_a_photo_rounded, color: Colors.white),
                      label: const Text(
                        'Chọn ảnh',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                if (_aiResult != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(top: 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [successColor.withOpacity(0.1), successColor.withOpacity(0.05)],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: successColor.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: successColor.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.smart_toy_rounded, color: successColor, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'AI nhận diện',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: successColor,
                                ),
                              ),
                              Text(
                                _aiResult!,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: currentTextPrimaryColor,
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
        ],
      ),
    );
  }

  Widget _buildFormSection() {
    return Container(
      decoration: BoxDecoration(
        color: currentSurfaceColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Thông tin thực phẩm',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 20),
          // Name Field
          _buildModernTextField(
            controller: _nameController,
            label: 'Tên thực phẩm',
            hint: 'Nhập tên thực phẩm',
            icon: Icons.fastfood_rounded,
            validator: _validateName,
          ),
          const SizedBox(height: 16),
          // Quantity and Unit Row
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildModernTextField(
                  controller: _quantityController,
                  label: 'Số lượng',
                  hint: '0',
                  icon: Icons.scale_rounded,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  validator: _validateQuantity,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: _buildModernDropdown<String>(
                  value: _unitId,
                  label: 'Đơn vị',
                  icon: Icons.straighten_rounded,
                  items: [
                    ..._units.map((unit) => DropdownMenuItem<String>(
                      value: unit['id'],
                      child: Text(
                        unit['name'] ?? 'N/A',
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    )),
                    DropdownMenuItem<String>(
                      value: 'add_new_unit',
                      child: Text(
                        'Thêm mới',
                        style: TextStyle(color: primaryColor),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == 'add_new_unit') {
                      _showAddUnitDialog();
                    } else {
                      setState(() => _unitId = value);
                    }
                  },
                  validator: (value) =>
                  value == null || value == 'add_new_unit' ? 'Vui lòng chọn đơn vị' : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Category Dropdown
          _buildModernDropdown<String>(
            value: _selectedCategoryId,
            label: 'Danh mục',
            icon: Icons.category_rounded,
            items: [
              ..._foodCategories.map((category) => DropdownMenuItem<String>(
                value: category['id'],
                child: Text(
                  category['name'] ?? 'Không xác định',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              )),
              DropdownMenuItem<String>(
                value: 'add_new_category',
                child: Text(
                  'Thêm mới',
                  style: TextStyle(color: primaryColor),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
            onChanged: (value) {
              if (value == 'add_new_category') {
                _showAddCategoryDialog();
              } else {
                setState(() => _selectedCategoryId = value);
              }
            },
            validator: (value) =>
            value == null || value == 'add_new_category' ? 'Vui lòng chọn danh mục' : null,
          ),
          const SizedBox(height: 16),
          // Expiry Date
          _buildDateSelector(),
          const SizedBox(height: 16),
          // Storage Area Dropdown
          _buildModernDropdown<String>(
            value: _selectedAreaId,
            label: 'Khu vực lưu trữ',
            icon: Icons.kitchen_rounded,
            items: _storageAreas.map((area) => DropdownMenuItem<String>(
              value: area['id'],
              child: Text(
                area['name'] ?? 'Không xác định',
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            )).toList(),
            onChanged: (value) => setState(() => _selectedAreaId = value),
            validator: (value) => value == null ? 'Vui lòng chọn khu vực' : null,
          ),
        ],
      ),
    );
  }

  Widget _buildModernTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: validator,
          style: TextStyle(
            fontSize: 16,
            color: currentTextPrimaryColor,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: currentTextSecondaryColor),
            prefixIcon: Icon(icon, color: primaryColor, size: 20),
            filled: true,
            fillColor: currentBackgroundColor.withOpacity(0.1),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: errorColor),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          ),
        ),
      ],
    );
  }

  Widget _buildModernDropdown<T>({
    required T? value,
    required String label,
    required IconData icon,
    required List<DropdownMenuItem<T>> items,
    required void Function(T?) onChanged,
    String? Function(T?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField2<T>(
          value: value,
          items: items,
          onChanged: onChanged,
          validator: validator,
          isDense: true,
          isExpanded: true,
          style: TextStyle(
            fontSize: 16,
            color: currentTextPrimaryColor,
          ),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: primaryColor, size: 20),
            filled: true,
            fillColor: currentBackgroundColor.withOpacity(0.1),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: primaryColor, width: 2),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide(color: errorColor),
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          ),
          dropdownStyleData: DropdownStyleData(
            maxHeight: 200,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: currentSurfaceColor,
            ),
            scrollbarTheme: ScrollbarThemeData(
              radius: const Radius.circular(40),
              thickness: WidgetStateProperty.all(6),
              thumbVisibility: WidgetStateProperty.all(true),
            ),
          ),
          menuItemStyleData: const MenuItemStyleData(
            height: 40,
            padding: EdgeInsets.symmetric(horizontal: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildDateSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ngày hết hạn',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: currentBackgroundColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _isLoading ? null : () async {
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
                          surface: currentSurfaceColor,
                          onSurface: currentTextPrimaryColor,
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
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today_rounded, color: primaryColor, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${_expiryDate.day}/${_expiryDate.month}/${_expiryDate.year}',
                        style: TextStyle(
                          fontSize: 16,
                          color: currentTextPrimaryColor,
                        ),
                      ),
                    ),
                    Icon(Icons.arrow_drop_down_rounded, color: currentTextSecondaryColor),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}