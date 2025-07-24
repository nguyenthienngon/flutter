import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:debounce_throttle/debounce_throttle.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config.dart';
import 'package:intl/intl.dart';

class FoodDetailScreen extends StatefulWidget {
  final String storageLogId;
  final String userId;
  final Map<String, dynamic>? initialLog;
  final bool isDarkMode; // Thêm tham số isDarkMode

  const FoodDetailScreen({
    super.key,
    required this.storageLogId,
    required this.userId,
    this.initialLog,
    required this.isDarkMode, // Nhận chế độ tối từ HomeScreen
  });

  @override
  _FoodDetailScreenState createState() => _FoodDetailScreenState();
}

class _FoodDetailScreenState extends State<FoodDetailScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _headerAnimationController;
  late Animation<double> _scaleAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;
  late Animation<double> _headerSlideAnimation;

  Map<String, dynamic>? _foodLog;
  late TextEditingController _nameController;
  late TextEditingController _quantityController;
  DateTime? _selectedExpiryDate;
  String? _selectedAreaId;
  DateTime? _storageDate;
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
  final DateFormat _customDateFormat = DateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'");

  // Getter màu sắc động dựa trên chế độ tối
  Color get currentBackgroundColor => widget.isDarkMode ? const Color(0xFF121212) : const Color(0xFFE6F7FF);
  Color get currentSurfaceColor => widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white;
  Color get currentTextPrimaryColor => widget.isDarkMode ? const Color(0xFFE0E0E0) : const Color(0xFF202124);
  Color get currentTextSecondaryColor => widget.isDarkMode ? const Color(0xFFB0B0B0) : const Color(0xFF5F6368);

  final Color primaryColor = const Color(0xFF0078D7);
  final Color secondaryColor = const Color(0xFF50E3C2);
  final Color accentColor = const Color(0xFF00B294);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color errorColor = const Color(0xFFE74C3C);

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _nameController = TextEditingController();
    _quantityController = TextEditingController();
    _fetchAllData();
  }

  void _initializeAnimations() {
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _headerAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOutBack),
    );

    _slideAnimation = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _headerSlideAnimation = Tween<double>(begin: -50.0, end: 0.0).animate(
      CurvedAnimation(parent: _headerAnimationController, curve: Curves.easeOut),
    );
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
      if (mounted) {
        _headerAnimationController.forward();
        Future.delayed(const Duration(milliseconds: 200), () {
          if (mounted) _animationController.forward();
        });
      }
    } catch (e) {
      print('Error fetching all data: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _headerAnimationController.dispose();
    _nameController.dispose();
    _quantityController.dispose();
    _nameDebouncer.cancel();
    super.dispose();
  }

  Future<void> _fetchInitialData() async {
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
              'storageDate': null,
              'unitName': 'Unknown Unit',
              'imageUrl': null,
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
            'storageDate': null,
            'unitName': 'Unknown Unit',
            'imageUrl': null,
          };
        }
      }

      // Fetch imageUrl from Firestore
      if (_foodLog?['foodId'] != null) {
        final foodDoc = await _firestore.collection('Foods').doc(_foodLog!['foodId']).get();
        if (foodDoc.exists) {
          final foodData = foodDoc.data();
          _foodLog!['imageUrl'] = foodData?['imageUrl'];
        }
      }

      // Fetch categoryName from API if needed
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
        'storageDate': null,
        'unitName': 'Unknown Unit',
        'imageUrl': null,
      };
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
      print('Error fetching storage areas: $e');
    }
  }

  Future<void> _fetchUnits() async {
    try {
      final snapshot = await _firestore.collection('Units').get();
      setState(() {
        _units = snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
      });
    } catch (e) {
      print('Error fetching units: $e');
    }
  }

  void _updateUIFromLog() {
    _nameController.text = _foodLog?['foodName'] ?? 'Unknown';
    _quantityController.text = (_foodLog?['quantity'] as num?)?.toString() ?? '0';
    _selectedAreaId = _foodLog?['areaId'];
    _selectedExpiryDate = _parseDate(_foodLog?['expiryDate']);
    _storageDate = _parseDate(_foodLog?['storageDate']);
    _selectedUnitName = _foodLog?['unitName'] ?? _units.firstWhere(
          (unit) => unit['id'] == _foodLog?['unitId'],
      orElse: () => {'name': 'Unknown Unit'},
    )['name'] ?? 'Unknown Unit';
  }

  DateTime? _parseDate(dynamic dateData) {
    if (dateData is String) {
      try {
        return _customDateFormat.parse(dateData, true).toUtc().toLocal();
      } catch (e) {
        print('Custom date parsing failed for $dateData: $e');
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
      _showSnackBar('Số lượng không thể âm', errorColor);
      setState(() => _isSaving = false);
      return;
    }

    try {
      final foodId = _foodLog?['foodId'];
      if (foodId == null) {
        _showSnackBar('Không tìm thấy foodId', errorColor);
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
          'imageUrl': _foodLog?['imageUrl'],
        });

        transaction.update(storageLogRef, {
          'quantity': quantity,
          'expiryDate': _selectedExpiryDate != null ? Timestamp.fromDate(_selectedExpiryDate!) : null,
          'areaId': _selectedAreaId,
          'unitId': _foodLog?['unitId'],
          'updatedAt': FieldValue.serverTimestamp(),
        });
      });

      // Cập nhật _foodLog với dữ liệu mới
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
          'storageDate': updatedStorageLogDoc['storageDate'],
          'imageUrl': updatedFoodDoc['imageUrl'],
        };
        _updateUIFromLog();
      }

      _showSnackBar('Cập nhật thành công!', successColor);
      // Truyền tên mới và foodId trở lại HomeScreen
      Navigator.pop(context, {
        'refreshStorageLogs': true,
        'refreshFoods': true,
        'foodId': foodId,
        'foodName': _nameController.text.trim(), // Thêm tên mới
      });
    } catch (e) {
      _showSnackBar('Lỗi: $e', errorColor);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
  Future<void> _deleteFoodAndStorageLogs() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: errorColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.warning_rounded, color: errorColor, size: 24),
            ),
            const SizedBox(width: 12),
            const Text('Xác nhận xóa', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa "${_nameController.text}" và tất cả bản ghi liên quan?',
          style: TextStyle(color: currentTextSecondaryColor, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: errorColor,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Xóa', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      final foodId = _foodLog?['foodId'];
      if (foodId == null) {
        _showSnackBar('Không tìm thấy foodId', errorColor);
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

      _showSnackBar('Xóa thành công!', successColor);
      await _navigateBackWithRefresh();
    } catch (e) {
      _showSnackBar('Lỗi: $e', errorColor);
    }
  }

  Future<void> _navigateBackWithRefresh() async {
    Navigator.pop(context, {
      'refreshStorageLogs': true,
      'refreshFoods': true,
      'foodId': _foodLog?['foodId'],
      'foodName': _nameController.text.trim(), // Thêm tên mới
    });
  }

  void _showSnackBar(String message, Color backgroundColor) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              backgroundColor == successColor ? Icons.check_circle_outline : Icons.error_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500))),
          ],
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
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
              surface: currentSurfaceColor,
              onSurface: currentTextPrimaryColor,
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
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: currentSurfaceColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
            const SizedBox(height: 20),
            Text(
              'Chọn khu vực',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
              ),
            ),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.5,
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: areas.length,
                itemBuilder: (context, index) {
                  final area = areas[index];
                  final isSelected = _selectedAreaId == area['id'];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      gradient: isSelected
                          ? LinearGradient(colors: [primaryColor, accentColor])
                          : null,
                      color: isSelected ? null : currentBackgroundColor.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? Colors.transparent : currentTextSecondaryColor.withOpacity(0.2),
                      ),
                    ),
                    child: ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isSelected ? Colors.white.withOpacity(0.2) : primaryColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.location_on_rounded,
                          color: isSelected ? Colors.white : primaryColor,
                          size: 20,
                        ),
                      ),
                      title: Text(
                        area['name'] ?? 'Unknown Area',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? Colors.white : currentTextPrimaryColor,
                        ),
                      ),
                      onTap: () {
                        if (mounted) {
                          setState(() => _selectedAreaId = area['id']);
                        }
                        Navigator.pop(context);
                      },
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getFoodIcon(String foodName) {
    final name = foodName.toLowerCase();
    if (name.contains('thịt') || name.contains('gà') || name.contains('heo')) {
      return Icons.set_meal_rounded;
    } else if (name.contains('rau') || name.contains('củ')) {
      return Icons.eco_rounded;
    } else if (name.contains('trái') || name.contains('quả')) {
      return Icons.apple_rounded;
    } else if (name.contains('sữa') || name.contains('yaourt')) {
      return Icons.local_drink_rounded;
    }
    return Icons.fastfood_rounded;
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _foodLog == null) {
      return Scaffold(
        backgroundColor: currentBackgroundColor,
        body: Center(
          child: Container(
            padding: const EdgeInsets.all(32),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                  strokeWidth: 3.0,
                ),
                const SizedBox(height: 20),
                Text(
                  'Đang tải dữ liệu...',
                  style: TextStyle(
                    color: currentTextPrimaryColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
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

    Color statusColor = successColor;
    String statusText = 'Tươi';
    IconData statusIcon = Icons.check_circle_rounded;

    if (daysLeft <= 0) {
      statusColor = errorColor;
      statusText = 'Hết hạn';
      statusIcon = Icons.error_rounded;
    } else if (daysLeft <= 3) {
      statusColor = warningColor;
      statusText = 'Sắp hết hạn';
      statusIcon = Icons.warning_rounded;
    } else if (_selectedExpiryDate == null) {
      statusColor = currentTextSecondaryColor;
      statusText = 'Không rõ';
      statusIcon = Icons.help_rounded;
    }

    return Scaffold(
      backgroundColor: currentBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            // Modern Header
            AnimatedBuilder(
              animation: _headerSlideAnimation,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _headerSlideAnimation.value),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryColor, accentColor],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withOpacity(0.3),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'Chi tiết thực phẩm',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _getFoodIcon(_foodLog?['foodName'] ?? ''),
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),

            // Content
            Expanded(
              child: AnimatedBuilder(
                animation: _fadeAnimation,
                builder: (context, child) {
                  return Opacity(
                    opacity: _fadeAnimation.value,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: ScaleTransition(
                        scale: _scaleAnimation,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Status Card
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(20),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [statusColor.withOpacity(0.1), statusColor.withOpacity(0.05)],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: statusColor.withOpacity(0.3)),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: statusColor.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Icon(statusIcon, color: statusColor, size: 24),
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Trạng thái',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: currentTextSecondaryColor,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            statusText,
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                              color: statusColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (_selectedExpiryDate != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: statusColor.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Text(
                                          daysLeft > 0 ? '$daysLeft ngày' : 'Đã hết hạn',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: statusColor,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 24),

                              // Main Info Card
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: currentSurfaceColor,
                                  borderRadius: BorderRadius.circular(24),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.08),
                                      blurRadius: 20,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Image Section
                                    if (_foodLog!['imageUrl'] != null)
                                      ClipRRect(
                                        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                                        child: Image.network(
                                          _foodLog!['imageUrl'],
                                          height: 200,
                                          width: double.infinity,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) {
                                            return Container(
                                              height: 200,
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  colors: [primaryColor.withOpacity(0.1), accentColor.withOpacity(0.1)],
                                                  begin: Alignment.topLeft,
                                                  end: Alignment.bottomRight,
                                                ),
                                              ),
                                              child: Center(
                                                child: Icon(
                                                  _getFoodIcon(_foodLog?['foodName'] ?? ''),
                                                  size: 64,
                                                  color: primaryColor,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      )
                                    else
                                      Container(
                                        height: 200,
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            colors: [primaryColor.withOpacity(0.1), accentColor.withOpacity(0.1)],
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ),
                                          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                                        ),
                                        child: Center(
                                          child: Icon(
                                            _getFoodIcon(_foodLog?['foodName'] ?? ''),
                                            size: 64,
                                            color: primaryColor,
                                          ),
                                        ),
                                      ),

                                    // Form Section
                                    Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          // Category
                                          Text(
                                            _foodLog?['categoryName'] ?? 'Unknown Category',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                              color: primaryColor,
                                            ),
                                          ),
                                          const SizedBox(height: 20),

                                          // Food Name
                                          _buildModernTextField(
                                            controller: _nameController,
                                            label: 'Tên thực phẩm',
                                            icon: Icons.fastfood_rounded,
                                            onChanged: (value) => _nameDebouncer.value = value,
                                          ),
                                          const SizedBox(height: 20),

                                          // Quantity
                                          _buildModernTextField(
                                            controller: _quantityController,
                                            label: 'Số lượng',
                                            icon: Icons.numbers_rounded,
                                            keyboardType: TextInputType.number,
                                            suffix: Text(
                                              _selectedUnitName ?? 'Unknown Unit',
                                              style: TextStyle(
                                                fontSize: 16,
                                                color: currentTextSecondaryColor,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            onChanged: (value) {
                                              if (int.tryParse(value) == null && value.isNotEmpty) {
                                                _quantityController.text = '0';
                                                _quantityController.selection = TextSelection.fromPosition(
                                                  TextPosition(offset: 1),
                                                );
                                                _showSnackBar('Vui lòng nhập số lượng hợp lệ', warningColor);
                                              }
                                            },
                                          ),
                                          const SizedBox(height: 20),

                                          // Area Selection
                                          _buildModernSelector(
                                            label: 'Khu vực',
                                            value: areaName,
                                            icon: Icons.location_on_rounded,
                                            onTap: () => _selectArea(context, _storageAreas),
                                          ),
                                          const SizedBox(height: 20),

                                          // Expiry Date
                                          _buildModernSelector(
                                            label: 'Ngày hết hạn',
                                            value: _selectedExpiryDate != null
                                                ? '${_selectedExpiryDate!.day}/${_selectedExpiryDate!.month}/${_selectedExpiryDate!.year}'
                                                : 'Chọn ngày',
                                            icon: Icons.calendar_today_rounded,
                                            onTap: () => _selectDate(context),
                                          ),
                                          const SizedBox(height: 20),

                                          // Storage Date Info
                                          _buildInfoRow(
                                            'Ngày tạo',
                                            _storageDate != null
                                                ? '${_storageDate!.day}/${_storageDate!.month}/${_storageDate!.year}'
                                                : 'Unknown',
                                            Icons.create_rounded,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 32),

                              // Action Buttons
                              Row(
                                children: [
                                  Expanded(
                                    child: Container(
                                      height: 56,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [accentColor, successColor],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                        borderRadius: BorderRadius.circular(16),
                                        boxShadow: [
                                          BoxShadow(
                                            color: accentColor.withOpacity(0.3),
                                            blurRadius: 12,
                                            offset: const Offset(0, 6),
                                          ),
                                        ],
                                      ),
                                      child: ElevatedButton.icon(
                                        onPressed: _isSaving ? null : _updateFoodAndStorageLog,
                                        icon: _isSaving
                                            ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                            : const Icon(Icons.save_rounded, color: Colors.white, size: 20),
                                        label: Text(
                                          _isSaving ? 'Đang lưu...' : 'Lưu thay đổi',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.transparent,
                                          shadowColor: Colors.transparent,
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(16),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  Container(
                                    height: 56,
                                    decoration: BoxDecoration(
                                      color: currentSurfaceColor,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: errorColor, width: 2),
                                      boxShadow: [
                                        BoxShadow(
                                          color: errorColor.withOpacity(0.1),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: IconButton(
                                      onPressed: _isSaving ? null : _deleteFoodAndStorageLogs,
                                      icon: Icon(Icons.delete_rounded, color: errorColor, size: 24),
                                      tooltip: 'Xóa thực phẩm',
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 32),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModernTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    Widget? suffix,
    Function(String)? onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: currentBackgroundColor.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primaryColor.withOpacity(0.2)),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: currentTextPrimaryColor,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: currentTextSecondaryColor, fontWeight: FontWeight.w500),
          prefixIcon: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: primaryColor, size: 20),
          ),
          suffixIcon: suffix != null ? Padding(
            padding: const EdgeInsets.all(16),
            child: suffix,
          ) : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }

  Widget _buildModernSelector({
    required String label,
    required String value,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: currentBackgroundColor.withOpacity(0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: primaryColor.withOpacity(0.2)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: primaryColor, size: 20),
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
                      color: currentTextSecondaryColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: currentTextPrimaryColor,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios_rounded, color: currentTextSecondaryColor, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: primaryColor.withOpacity(0.05),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: primaryColor.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: primaryColor, size: 20),
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
                    color: currentTextSecondaryColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: currentTextPrimaryColor,
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