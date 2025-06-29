import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config.dart';
import 'home_screen.dart';
import 'package:intl/intl.dart'; // Thêm package intl

class FoodDetailScreen extends StatefulWidget {
  final String storageLogId;
  final String userId;
  final Map<String, dynamic>? initialLog;

  const FoodDetailScreen({
    super.key,
    required this.storageLogId,
    required this.userId,
    this.initialLog,
  });

  @override
  _FoodDetailScreenState createState() => _FoodDetailScreenState();
}

class _FoodDetailScreenState extends State<FoodDetailScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;
  Map<String, dynamic>? _foodLog;
  late TextEditingController _nameController;
  late TextEditingController _quantityController;
  DateTime? _selectedExpiryDate;
  String? _selectedAreaId;
  DateTime? _storageDate; // Sử dụng storageDate
  String? _selectedUnitName;
  List<Map<String, dynamic>> _storageAreas = [];
  List<Map<String, dynamic>> _units = [];
  bool _isLoading = true;
  bool _isSaving = false;

  final _nameDebouncer = Debouncer<String>(
    const Duration(milliseconds: 500),
    initialValue: '',
    onChanged: (value) {},
  );

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Color primaryColor = const Color(0xFF0078D7);
  final Color accentColor = const Color(0xFF00B294);
  final Color textLightColor = const Color(0xFF5F6368);
  final DateFormat _customDateFormat = DateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'"); // Định dạng tùy chỉnh

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _slideAnimation = Tween<Offset>(begin: const Offset(0, 0.2), end: Offset.zero).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _nameController = TextEditingController();
    _quantityController = TextEditingController();
    _fetchAllData();
  }

  Future<void> _fetchAllData() async {
    setState(() => _isLoading = true);
    try {
      await Future.wait([
        _fetchInitialData().catchError((e) => print('Error fetching initial data: $e')),
        _fetchStorageAreas().catchError((e) => print('Error fetching storage areas: $e')),
        _fetchUnits().catchError((e) => print('Error fetching units: $e')),
      ]);
      _updateUIFromLog();
      if (mounted) _animationController.forward();
    } catch (e) {
      print('Error fetching all data: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _nameController.dispose();
    _quantityController.dispose();
    _nameDebouncer.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
    setState(() => _isLoading = true);
    try {
      print('Fetching initial data for storageLogId: ${widget.storageLogId}');
      if (widget.initialLog != null && widget.initialLog!.isNotEmpty) {
        _foodLog = Map<String, dynamic>.from(widget.initialLog!);
        print('Using initialLog: $_foodLog');
      } else {
        final response = await http.get(
          Uri.parse('${Config.getNgrokUrl()}/get_sorted_storage_logs?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final logs = data['logs'] as List<dynamic>? ?? [];
          _foodLog = logs.firstWhere(
                (log) => log['id'] == widget.storageLogId,
            orElse: () => {
              'foodName': 'Unknown',
              'id': widget.storageLogId,
              'quantity': 0,
              'areaId': null,
              'expiryDate': null,
              'categoryName': 'Unknown Category',
              'storageDate': null, // Sử dụng storageDate
              'unitName': 'Unknown Unit',
              'imageUrl': null, // Thêm imageUrl mặc định
            },
          );
          print('Fetched log from API: $_foodLog');
        } else {
          print('API error: ${response.statusCode} - ${response.body}');
          _foodLog = {
            'foodName': 'Unknown',
            'id': widget.storageLogId,
            'quantity': 0,
            'areaId': null,
            'expiryDate': null,
            'categoryName': 'Unknown Category',
            'storageDate': null, // Sử dụng storageDate
            'unitName': 'Unknown Unit',
            'imageUrl': null, // Thêm imageUrl mặc định
          };
        }
      }

      // Lấy foodId và truy vấn imageUrl từ Firestore
      if (_foodLog?['foodId'] != null) {
        final foodDoc = await _firestore.collection('Foods').doc(_foodLog!['foodId']).get();
        if (foodDoc.exists) {
          final foodData = foodDoc.data() as Map<String, dynamic>?;
          _foodLog!['imageUrl'] = foodData?['imageUrl'];
        }
      }

      // Kiểm tra và lấy categoryName từ API nếu cần
      if (_foodLog?['categoryName'] == 'Unknown Category' && _foodLog?['foodId'] != null) {
        final categoryName = await _fetchCategoryNameFromApi(_foodLog!['foodId']);
        _foodLog!['categoryName'] = categoryName;
      }
      _updateUIFromLog();
    } catch (e) {
      print('Error fetching initial data: $e');
      _foodLog ??= {
        'foodName': 'Unknown',
        'id': widget.storageLogId,
        'quantity': 0,
        'areaId': null,
        'expiryDate': null,
        'categoryName': 'Unknown Category',
        'storageDate': null, // Sử dụng storageDate
        'unitName': 'Unknown Unit',
        'imageUrl': null, // Thêm imageUrl mặc định
      };
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<String> _fetchCategoryNameFromApi(String foodId) async {
    try {
      final response = await http.get(
        Uri.parse('${Config.getNgrokUrl()}/get_food_category_name?foodId=$foodId'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['name'] ?? 'Unknown Category';
      } else {
        print('Failed to fetch category name: ${response.body}');
        return 'Unknown Category';
      }
    } catch (e) {
      print('Error fetching category name from API: $e');
      return 'Unknown Category';
    }
  }

  Future<void> _fetchStorageAreas() async {
    try {
      final snapshot = await _firestore.collection('StorageAreas').get();
      setState(() {
        _storageAreas = snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
        _selectedAreaId ??= _foodLog?['areaId'] ?? (_storageAreas.isNotEmpty ? _storageAreas[0]['id'] : null);
      });
    } catch (e) {
      print('Lỗi khi lấy khu vực: $e');
    }
  }

  Future<void> _fetchUnits() async {
    try {
      final snapshot = await _firestore.collection('Units').get();
      setState(() {
        _units = snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
      });
    } catch (e) {
      print('Lỗi khi lấy đơn vị: $e');
    }
  }

  void _updateUIFromLog() {
    _nameController.text = _foodLog?['foodName'] ?? 'Unknown';
    _quantityController.text = (_foodLog?['quantity'] as num?)?.toString() ?? '0';
    _selectedAreaId = _foodLog?['areaId'];
    _selectedExpiryDate = _parseDate(_foodLog?['expiryDate']);
    _storageDate = _parseDate(_foodLog?['storageDate']); // Sử dụng storageDate
    _selectedUnitName = _foodLog?['unitName'] ?? _units.firstWhere(
          (unit) => unit['id'] == _foodLog?['unitId'],
      orElse: () => {'name': 'Unknown Unit'},
    )['name'] ?? 'Unknown Unit';
  }

  DateTime? _parseDate(dynamic dateData) {
    if (dateData is String) {
      // Thử parse với định dạng tùy chỉnh "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
      try {
        return _customDateFormat.parse(dateData, true).toUtc().toLocal();
      } catch (e) {
        print('Custom date parsing failed for $dateData: $e');
        // Nếu thất bại, thử với DateTime.tryParse
        return DateTime.tryParse(dateData) ?? DateTime.tryParse(dateData.split('.')[0]);
      }
    } else if (dateData is DateTime) {
      return dateData;
    } else if (dateData is Timestamp) {
      return dateData.toDate();
    }
    return null;
  }

  Future<void> _updateFoodAndStorageLog() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final quantity = int.tryParse(_quantityController.text) ?? 0;
    if (quantity < 0) {
      _showSnackBar('Số lượng không thể âm', Colors.red);
      setState(() => _isSaving = false);
      return;
    }

    try {
      final foodId = _foodLog?['foodId'];
      if (foodId == null) {
        _showSnackBar('Không tìm thấy foodId', Colors.red);
        await _navigateBackWithRefresh();
        return;
      }

      final foodRef = _firestore.collection('Foods').doc(foodId);
      final storageLogRef = _firestore.collection('StorageLogs').doc(widget.storageLogId);

      await _firestore.runTransaction((transaction) async {
        final foodDoc = await transaction.get(foodRef);
        final storageLogDoc = await transaction.get(storageLogRef);

        if (!foodDoc.exists || foodDoc['userId'] != widget.userId) {
          throw Exception('Unauthorized or Food not found');
        }
        if (!storageLogDoc.exists || storageLogDoc['userId'] != widget.userId) {
          throw Exception('Unauthorized or StorageLog not found');
        }

        transaction.update(foodRef, {
          'name': _nameController.text.trim(),
          'updatedAt': FieldValue.serverTimestamp(),
          'imageUrl': _foodLog?['imageUrl'], // Giữ nguyên imageUrl
        });

        transaction.update(storageLogRef, {
          'quantity': quantity,
          'expiryDate': _selectedExpiryDate != null ? Timestamp.fromDate(_selectedExpiryDate!) : null,
          'areaId': _selectedAreaId,
          'unitId': _foodLog?['unitId'],
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      final updatedFoodDoc = await foodRef.get();
      final updatedStorageLogDoc = await storageLogRef.get();
      if (updatedFoodDoc.exists && updatedStorageLogDoc.exists) {
        _foodLog = {
          ..._foodLog!,
          'foodName': updatedFoodDoc['name'],
          'quantity': updatedStorageLogDoc['quantity'],
          'expiryDate': updatedStorageLogDoc['expiryDate'],
          'areaId': updatedStorageLogDoc['areaId'],
          'unitId': updatedStorageLogDoc['unitId'],
          'updatedAt': updatedStorageLogDoc['updatedAt'],
          'storageDate': updatedStorageLogDoc['storageDate'], // Cập nhật storageDate
          'imageUrl': updatedFoodDoc['imageUrl'], // Cập nhật imageUrl
        };
        _updateUIFromLog();
      }

      _showSnackBar('Cập nhật thành công!', accentColor);
      await _navigateBackWithRefresh();
    } catch (e) {
      _showSnackBar('Lỗi: $e', Colors.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _deleteFoodAndStorageLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận xóa', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Bạn có chắc chắn muốn xóa "${_nameController.text}" và tất cả bản ghi liên quan?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xóa', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

    if (confirm != true) return;

    try {
      final foodId = _foodLog?['foodId'];
      if (foodId == null) {
        _showSnackBar('Không tìm thấy foodId', Colors.red);
        await _navigateBackWithRefresh();
        return;
      }

      await _firestore.runTransaction((transaction) async {
        final foodRef = _firestore.collection('Foods').doc(foodId);
        final storageLogRef = _firestore.collection('StorageLogs').doc(widget.storageLogId);

        final foodDoc = await transaction.get(foodRef);
        final storageLogDoc = await transaction.get(storageLogRef);

        if (!foodDoc.exists || foodDoc['userId'] != widget.userId) {
          throw Exception('Unauthorized or Food not found');
        }
        if (!storageLogDoc.exists || storageLogDoc['userId'] != widget.userId) {
          throw Exception('Unauthorized or StorageLog not found');
        }

        transaction.delete(foodRef);
        transaction.delete(storageLogRef);
      });

      _showSnackBar('Xóa thành công!', accentColor);
      await _navigateBackWithRefresh();
    } catch (e) {
      _showSnackBar('Lỗi: $e', Colors.red);
    }
  }

  Future<void> _navigateBackWithRefresh() async {
    Navigator.pop(context, {
      'refreshStorageLogs': true,
      'refreshFoods': true,
      'foodId': _foodLog?['foodId'],
    });
  }

  void _showSnackBar(String message, Color backgroundColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
          ],
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedExpiryDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: primaryColor,
              onPrimary: Colors.white,
              surface: Colors.white,
              onSurface: const Color(0xFF202124),
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: primaryColor),
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null && picked != _selectedExpiryDate && mounted) {
      setState(() => _selectedExpiryDate = picked);
    }
  }

  Future<void> _selectArea(BuildContext context, List<Map<String, dynamic>> areas) async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Chọn khu vực',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF202124)),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: areas.length,
                itemBuilder: (context, index) {
                  final area = areas[index];
                  return ListTile(
                    leading: Icon(Icons.location_on, color: primaryColor, size: 24),
                    title: Text(area['name'] ?? 'Unknown Area',
                        style: const TextStyle(fontSize: 18, color: Color(0xFF202124))),
                    onTap: () {
                      if (mounted) {
                        setState(() => _selectedAreaId = area['id']);
                      }
                      Navigator.pop(context);
                    },
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    tileColor: Colors.grey[50],
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _foodLog == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF0078D7)))),
      );
    }

    final area = _storageAreas.firstWhere(
          (area) => area['id'] == _selectedAreaId,
      orElse: () => {'name': 'Unknown Area'},
    );
    final areaName = area['name'] ?? 'Unknown Area';

    final daysLeft = _selectedExpiryDate != null
        ? _selectedExpiryDate!.difference(DateTime.now()).inDays
        : 999;

    Color statusColor = const Color(0xFF4CAF50);
    String statusText = 'Tươi';
    IconData statusIcon = Icons.check_circle;

    if (daysLeft <= 0) {
      statusColor = Colors.red;
      statusText = 'Hết hạn';
      statusIcon = Icons.error;
    } else if (daysLeft <= 3) {
      statusColor = const Color(0xFFFF9800);
      statusText = 'Sắp hết hạn';
      statusIcon = Icons.warning;
    } else if (_selectedExpiryDate == null) {
      statusColor = Colors.grey;
      statusText = 'Không rõ';
      statusIcon = Icons.help;
    }

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [const Color(0xFFE6F7FF).withOpacity(0.8), Colors.white],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.white, const Color(0xFFFAFDFF)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_back_ios, color: primaryColor),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Text(
                        'Chi tiết thực phẩm',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF202124),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SlideTransition(
                  position: _slideAnimation,
                  child: ScaleTransition(
                    scale: _scaleAnimation,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [Colors.white, const Color(0xFFF5FAFF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.1),
                                  blurRadius: 15,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Thêm hình ảnh
                                _foodLog!['imageUrl'] != null
                                    ? ClipRRect(
                                  borderRadius: BorderRadius.circular(15),
                                  child: Image.network(
                                    _foodLog!['imageUrl'],
                                    height: 150,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) {
                                      return Container(
                                        height: 150,
                                        color: Colors.grey[300],
                                        child: const Center(
                                          child: Icon(Icons.error, color: Colors.red),
                                        ),
                                      );
                                    },
                                  ),
                                )
                                    : Container(
                                  height: 150,
                                  color: Colors.grey[300],
                                  child: const Center(
                                    child: Icon(Icons.image_not_supported, color: Colors.grey),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      width: 50,
                                      height: 50,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [statusColor.withOpacity(0.15), statusColor.withOpacity(0.05)],
                                          begin: Alignment.center,
                                          end: Alignment.bottomRight,
                                        ),
                                        borderRadius: BorderRadius.circular(15),
                                        border: Border.all(color: statusColor.withOpacity(0.2), width: 1),
                                      ),
                                      child: Icon(
                                        Icons.fastfood_outlined,
                                        color: statusColor,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _foodLog?['categoryName'] ?? 'Unknown Category',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                              color: textLightColor,
                                            ),
                                          ),
                                          const SizedBox(height: 6),
                                          TextField(
                                            controller: _nameController,
                                            decoration: InputDecoration(
                                              labelText: 'Tên thực phẩm',
                                              border: OutlineInputBorder(
                                                borderRadius: BorderRadius.circular(10),
                                                borderSide: BorderSide.none,
                                              ),
                                              filled: true,
                                              fillColor: Colors.grey[50],
                                              hintStyle: TextStyle(color: textLightColor),
                                            ),
                                            onChanged: (value) => _nameDebouncer.value = value,
                                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                const Divider(color: Color(0xFFD3DDE3), thickness: 1),
                                const SizedBox(height: 20),
                                TextField(
                                  controller: _quantityController,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: 'Số lượng',
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                    filled: true,
                                    fillColor: Colors.grey[50],
                                    suffixText: _selectedUnitName ?? 'Unknown Unit',
                                    suffixStyle: TextStyle(fontSize: 16, color: textLightColor),
                                  ),
                                  onChanged: (value) {
                                    if (int.tryParse(value) == null && value.isNotEmpty) {
                                      _quantityController.text = '0';
                                      _quantityController.selection = TextSelection.fromPosition(
                                        const TextPosition(offset: 1),
                                      );
                                      _showSnackBar('Vui lòng nhập số lượng hợp lệ', Colors.orange);
                                    }
                                  },
                                ),
                                const SizedBox(height: 16),
                                InkWell(
                                  onTap: () => _selectArea(context, _storageAreas),
                                  child: InputDecorator(
                                    decoration: InputDecoration(
                                      labelText: 'Khu vực',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                      filled: true,
                                      fillColor: Colors.grey[50],
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          areaName,
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                        Icon(Icons.arrow_drop_down, color: textLightColor),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                InkWell(
                                  onTap: () => _selectDate(context),
                                  child: InputDecorator(
                                    decoration: InputDecoration(
                                      labelText: 'Ngày hết hạn',
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                      filled: true,
                                      fillColor: Colors.grey[50],
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _selectedExpiryDate != null
                                              ? '${_selectedExpiryDate!.day}/${_selectedExpiryDate!.month}/${_selectedExpiryDate!.year}'
                                              : 'Chọn ngày',
                                          style: const TextStyle(fontSize: 16),
                                        ),
                                        Icon(Icons.calendar_today, color: textLightColor),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                _buildInfoRow(
                                  'Ngày tạo', // Sử dụng storageDate
                                  _storageDate != null
                                      ? '${_storageDate!.day}/${_storageDate!.month}/${_storageDate!.year}'
                                      : 'Unknown',
                                  Icons.create,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _isSaving ? null : _updateFoodAndStorageLog,
                                  icon: _isSaving
                                      ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                  )
                                      : Icon(Icons.save, color: Colors.white, size: 20),
                                  label: Text(
                                    _isSaving ? 'Đang lưu...' : 'Lưu',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: accentColor,
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    elevation: 6,
                                    shadowColor: accentColor.withOpacity(0.3),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _isSaving ? null : _deleteFoodAndStorageLogs,
                                  icon: const Icon(Icons.delete, color: Colors.red, size: 20),
                                  label: const Text(
                                    'Xóa',
                                    style: TextStyle(
                                      color: Colors.red,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: Colors.red),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    backgroundColor: Colors.white,
                                  ),
                                ),
                              ),
                            ],
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
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: textLightColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: textLightColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    color: textLightColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF202124),
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