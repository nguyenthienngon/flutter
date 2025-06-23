import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'dart:convert';
import 'package:loading_animation_widget/loading_animation_widget.dart';
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
    _fetchInitialData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _quantityController.dispose();
    _animationController.dispose();
    super.dispose();
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
      _showErrorSnackBar('Lỗi khi tải dữ liệu ban đầu');
    } finally {
      if (mounted) setState(() => _isLoading = false);
      _animationController.forward();
    }
  }

  Future<void> _fetchStorageAreas() async {
    try {
      final snapshot = await _firestore.collection('StorageAreas').get();
      setState(() {
        _storageAreas = snapshot.docs.map((doc) => {
          ...doc.data() as Map<String, dynamic>,
          'id': doc.id,
        }).toList();
        _selectedAreaId ??= _storageAreas.isNotEmpty ? _storageAreas[0]['id'] : null;
      });
    } catch (e) {
      print('Lỗi khi lấy khu vực lưu trữ: $e');
    }
  }

  Future<void> _fetchUnits() async {
    try {
      final snapshot = await _firestore.collection('Units').get();
      setState(() {
        _units = snapshot.docs.map((doc) => {
          ...doc.data() as Map<String, dynamic>,
          'id': doc.id,
        }).toList();
        _unitId ??= _units.isNotEmpty ? _units[0]['id'] : null;
      });
    } catch (e) {
      print('Lỗi khi lấy đơn vị: $e');
    }
  }

  Future<void> _fetchFoodCategories() async {
    try {
      final snapshot = await _firestore.collection('FoodCategories').get();
      setState(() {
        _foodCategories = snapshot.docs.map((doc) => {
          ...doc.data() as Map<String, dynamic>,
          'id': doc.id,
        }).toList();
        _selectedCategoryId ??= _foodCategories.isNotEmpty ? _foodCategories[0]['id'] : null;
      });
    } catch (e) {
      print('Lỗi khi lấy danh mục: $e');
    }
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
      _showErrorSnackBar('Lỗi khi chọn ảnh');
    }
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
      _showErrorSnackBar('Lỗi khi chụp ảnh');
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
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
            Text(
              'Chọn nguồn ảnh',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF202124),
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
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: const Color(0xFF202124),
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
    if (_isSaving || _formKey.currentState == null || !_formKey.currentState!.validate()) {
      _showErrorSnackBar('Vui lòng kiểm tra lại thông tin nhập vào.');
      return;
    }
    if (_selectedAreaId == null || _selectedCategoryId == null || _unitId == null) {
      _showErrorSnackBar('Vui lòng chọn khu vực, danh mục và đơn vị.');
      return;
    }

    setState(() => _isSaving = true);

    try {
      final foodResponse = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_food'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _nameController.text.trim(),
          'categoryId': _selectedCategoryId,
          'userId': widget.uid,
        }),
      );
      final foodData = jsonDecode(foodResponse.body);
      if (foodResponse.statusCode != 200) {
        throw Exception(foodData['error'] ?? 'Lỗi khi thêm thực phẩm');
      }
      final foodId = foodData['foodId'] as String?;
      if (foodId == null) throw Exception('Không nhận được foodId');

      // Format expiryDate to ISO 8601 with UTC+7
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
          'expiryDate': expiryDateString, // Send as ISO 8601 string
        }),
      );
      final storageData = jsonDecode(storageResponse.body);
      if (storageResponse.statusCode != 200) {
        throw Exception(storageData['error'] ?? 'Lỗi khi lưu nhật ký');
      }

      // Delay 2 seconds to simulate loading and refresh HomeScreen
      await Future.delayed(const Duration(seconds: 2));
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: const [
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
    } catch (e) {
      print("Exception: $e");
      _showErrorSnackBar('Lỗi khi lưu thực phẩm: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showErrorSnackBar(String message) {
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
    if (value == null || value.trim().isEmpty) return 'Vui lòng nhập tên thực phẩm';
    return null;
  }

  String? _validateQuantity(String? value) {
    if (value == null || value.trim().isEmpty) return 'Vui lòng nhập số lượng';
    final quantity = double.tryParse(value);
    if (quantity == null || quantity <= 0) return 'Số lượng phải lớn hơn 0';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final Color primaryColor = const Color(0xFF0078D7);
    final Color secondaryColor = const Color(0xFF50E3C2);
    final Color accentColor = const Color(0xFF00B294);
    final Color textDarkColor = const Color(0xFF202124);
    final Color textLightColor = const Color(0xFF5F6368);

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
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [const Color(0xFFE6F7FF), Colors.white],
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
                              ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
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
                                        Icon(Icons.add_photo_alternate_outlined, size: 40, color: Colors.grey[400]),
                                        const SizedBox(height: 6),
                                        Text(
                                          'Thêm ảnh thực phẩm',
                                          style: TextStyle(color: Colors.grey[600], fontSize: 14),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      children: [
                                        if (_image == null)
                                          Container(
                                            width: double.infinity,
                                            height: 36,
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [primaryColor.withOpacity(0.1), accentColor.withOpacity(0.1)],
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
                                              validator: (value) => value == null || value == 'add_new_unit' ? 'Vui lòng chọn hoặc thêm đơn vị' : null,
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
                                    validator: (value) => value == null || value == 'add_new_category' ? 'Vui lòng chọn hoặc thêm danh mục' : null,
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
                                      setState(() => _selectedAreaId = newValue);
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