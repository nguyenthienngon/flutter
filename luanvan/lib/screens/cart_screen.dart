import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config.dart';

class CartScreen extends StatefulWidget {
  final String userId;
  final bool isDarkMode; // Thêm isDarkMode vào constructor

  const CartScreen({
    super.key,
    required this.userId,
    required this.isDarkMode, // Yêu cầu tham số isDarkMode
  });

  @override
  _CartScreenState createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _headerAnimationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;
  late Animation<Offset> _headerSlideAnimation;
  late List<Map<String, dynamic>> _cartItems;
  final TextEditingController _manualInputController = TextEditingController();
  final Map<String, String> _foodNameCache = {};
  bool _isLoading = false;

  // Modern color scheme matching home screen
  final Color primaryColor = const Color(0xFF0078D7);
  final Color secondaryColor = const Color(0xFF50E3C2);
  final Color accentColor = const Color(0xFF00B294);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color errorColor = const Color(0xFFE74C3C);
  final Color backgroundColor = const Color(0xFFE6F7FF);
  final Color surfaceColor = Colors.white;
  final Color textPrimaryColor = const Color(0xFF202124);
  final Color textSecondaryColor = const Color(0xFF5F6368);
  final Color darkBackgroundColor = const Color(0xFF121212);
  final Color darkSurfaceColor = const Color(0xFF1E1E1E);
  final Color darkTextPrimaryColor = const Color(0xFFE0E0E0);
  final Color darkTextSecondaryColor = const Color(0xFFB0B0B0);

  // Hàm để lấy màu dựa trên chế độ tối
  Color get currentBackgroundColor => widget.isDarkMode ? darkBackgroundColor : backgroundColor;
  Color get currentSurfaceColor => widget.isDarkMode ? darkSurfaceColor : surfaceColor;
  Color get currentTextPrimaryColor => widget.isDarkMode ? darkTextPrimaryColor : textPrimaryColor;
  Color get currentTextSecondaryColor => widget.isDarkMode ? darkTextSecondaryColor : textSecondaryColor;

  @override
  void initState() {
    super.initState();
    _cartItems = [];

    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );

    _headerAnimationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    _slideAnimation = Tween<double>(begin: 30.0, end: 0.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );

    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _headerAnimationController,
      curve: Curves.elasticOut,
    ));

    _headerAnimationController.forward();
    _animationController.forward();
    _fetchCartItems();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _headerAnimationController.dispose();
    _manualInputController.dispose();
    super.dispose();
  }

  Future<void> _fetchCartItems() async {
    setState(() => _isLoading = true);

    try {
      final response = await http.get(
        Uri.parse('${Config.getNgrokUrl()}/get_shopping_list?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final items = List<Map<String, dynamic>>.from(data['items'] ?? []);

        setState(() {
          _cartItems = items.map((item) {
            if (item['foodId'] != null && !item.containsKey('name')) {
              return {
                ...item,
                'name': _foodNameCache[item['foodId']] ?? 'Thực phẩm không xác định',
              };
            }
            return item;
          }).toList();
          _isLoading = false;
        });

        await _fetchFoodNamesForItems();
      } else {
        throw Exception('Không thể lấy danh sách mua sắm: ${response.body}');
      }
    } catch (e) {
      print('Lỗi khi lấy danh sách mua sắm: $e');
      setState(() => _isLoading = false);
      _showErrorSnackBar('Lỗi khi tải danh sách: $e');
    }
  }

  Future<void> _fetchFoodNamesForItems() async {
    final foodIds = _cartItems
        .where((item) => item['foodId'] != null && !item.containsKey('name'))
        .map((item) => item['foodId'] as String)
        .toList();

    if (foodIds.isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/get_food_names'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'foodIds': foodIds}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final foodNames = data['foodNames'] as Map<String, dynamic>? ?? {};

        setState(() {
          for (var item in _cartItems) {
            if (item['foodId'] != null && !item.containsKey('name')) {
              item['name'] = foodNames[item['foodId']] ?? 'Thực phẩm không xác định';
              _foodNameCache[item['foodId']] = item['name']!;
            }
          }
        });
      }
    } catch (e) {
      print('Lỗi khi lấy tên thực phẩm: $e');
    }
  }

  Future<void> _updateQuantity(String itemId, int newQuantity) async {
    if (newQuantity <= 0) {
      _removeItem(itemId);
      return;
    }

    setState(() {
      final index = _cartItems.indexWhere((item) => item['id'] == itemId);
      if (index >= 0) {
        _cartItems[index]['quantity'] = newQuantity;
      }
    });

    try {
      final response = await http.put(
        Uri.parse('${Config.getNgrokUrl()}/update_shopping_list_item/$itemId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'quantity': newQuantity,
          'createdBy': widget.userId,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Không thể cập nhật số lượng: ${response.body}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi cập nhật: $e');
      setState(() {
        final index = _cartItems.indexWhere((item) => item['id'] == itemId);
        if (index >= 0) {
          _cartItems[index]['quantity'] = (_cartItems[index]['quantity'] ?? 1) +
              (newQuantity < (_cartItems[index]['quantity'] ?? 1) ? 1 : -1);
        }
      });
    }
  }

  Future<void> _removeItem(String itemId) async {
    final removedItem = _cartItems.firstWhere((item) => item['id'] == itemId);

    setState(() {
      _cartItems.removeWhere((item) => item['id'] == itemId);
    });

    try {
      final response = await http.delete(
        Uri.parse('${Config.getNgrokUrl()}/delete_shopping_list_item/$itemId?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        _showSuccessSnackBar('Đã xóa khỏi danh sách mua sắm!');
      } else {
        throw Exception('Không thể xóa mục: ${response.body}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi: $e');
      setState(() {
        _cartItems.add(removedItem);
      });
    }
  }

  Future<void> _clearCart() async {
    final confirmed = await _showDeleteConfirmDialog(
      'Xóa toàn bộ danh sách',
      'Bạn có chắc chắn muốn xóa toàn bộ danh sách mua sắm không?',
    );

    if (!confirmed) return;

    final originalItems = _cartItems.map((item) => Map<String, dynamic>.from(item)).toList();
    setState(() => _cartItems.clear());

    try {
      for (var item in originalItems) {
        await http.delete(
          Uri.parse('${Config.getNgrokUrl()}/delete_shopping_list_item/${item['id']}?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );
      }
      _showSuccessSnackBar('Đã xóa toàn bộ danh sách mua sắm!');
    } catch (e) {
      _showErrorSnackBar('Lỗi: $e');
      setState(() => _cartItems = originalItems);
    }
  }

  Future<void> _placeOrder() async {
    if (_cartItems.isEmpty) {
      _showErrorSnackBar('Danh sách mua sắm trống!');
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/place_order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': widget.userId,
          'items': _cartItems,
          'timestamp': DateTime.now().toIso8601String(),
          'status': 'pending',
        }),
      );

      if (response.statusCode == 200) {
        setState(() => _cartItems.clear());
        _showSuccessSnackBar('Danh sách mua sắm được cập nhật thành công!');
      } else {
        throw Exception('Không thể cập nhật danh sách mua sắm: ${response.body}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi khi cập nhật danh sách mua sắm: $e');
    }
  }

  void _showAddItemDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: currentSurfaceColor, // Sử dụng màu động
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: StatefulBuilder(
          builder: (context, setModalState) => Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[300],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [primaryColor.withOpacity(0.2), accentColor.withOpacity(0.2)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.add_shopping_cart, color: primaryColor, size: 24),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Thêm vào danh sách mua sắm',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: currentTextPrimaryColor, // Sử dụng màu động
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: currentBackgroundColor.withOpacity(0.3), // Sử dụng màu động
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: primaryColor.withOpacity(0.2)),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Thêm thủ công',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: currentTextPrimaryColor, // Sử dụng màu động
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _manualInputController,
                        decoration: InputDecoration(
                          hintText: 'Nhập tên mục cần mua',
                          hintStyle: TextStyle(color: currentTextSecondaryColor), // Sử dụng màu động
                          prefixIcon: Icon(Icons.edit_outlined, color: primaryColor),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: currentSurfaceColor, // Sử dụng màu động
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: primaryColor, width: 2),
                          ),
                        ),
                        style: TextStyle(color: currentTextPrimaryColor), // Sử dụng màu động
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _addManualItem(setModalState),
                          icon: const Icon(Icons.add, color: Colors.white),
                          label: const Text('Thêm', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: accentColor,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Hoặc chọn từ tủ lạnh:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: currentTextPrimaryColor, // Sử dụng màu động
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: currentBackgroundColor.withOpacity(0.3), // Sử dụng màu động
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: primaryColor.withOpacity(0.2)),
                  ),
                  child: _isLoading
                      ? Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                    ),
                  )
                      : FutureBuilder<List<Map<String, dynamic>>>(
                    future: _fetchStorageLogsForModal(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Center(
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                          ),
                        );
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.error_outline, color: errorColor, size: 32),
                              const SizedBox(height: 8),
                              Text(
                                'Lỗi khi tải danh sách kho',
                                style: TextStyle(color: currentTextSecondaryColor), // Sử dụng màu động
                              ),
                            ],
                          ),
                        );
                      }
                      final storageLogs = snapshot.data ?? [];
                      if (storageLogs.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.inventory_2_outlined, color: currentTextSecondaryColor, size: 32), // Sử dụng màu động
                              const SizedBox(height: 8),
                              Text(
                                'Không có thực phẩm trong tủ lạnh',
                                style: TextStyle(color: currentTextSecondaryColor), // Sử dụng màu động
                              ),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: storageLogs.length,
                        itemBuilder: (context, index) {
                          final log = storageLogs[index];
                          final foodName = log['foodName'] as String? ?? 'Thực phẩm không xác định';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: currentSurfaceColor, // Sử dụng màu động
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.05),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ListTile(
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: accentColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(Icons.fastfood, color: accentColor, size: 20),
                              ),
                              title: Text(
                                foodName,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: currentTextPrimaryColor, // Sử dụng màu động
                                ),
                              ),
                              trailing: Container(
                                decoration: BoxDecoration(
                                  color: successColor,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: IconButton(
                                  icon: const Icon(Icons.add, color: Colors.white, size: 20),
                                  onPressed: () => _addFromFridge(log, setModalState),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _addManualItem(StateSetter setModalState) async {
    if (_manualInputController.text.trim().isEmpty) {
      _showErrorSnackBar('Vui lòng nhập tên mục');
      return;
    }

    final newItem = {
      'id': '',
      'name': _manualInputController.text.trim(),
      'quantity': 1,
    };

    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_shopping_list_item'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': newItem['name'],
          'createdBy': widget.userId,
          'quantity': newItem['quantity'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        newItem['id'] = data['itemId'];

        setState(() {
          _cartItems.add(newItem);
        });

        _manualInputController.clear();
        Navigator.pop(context);
        _showSuccessSnackBar('Đã thêm vào danh sách mua sắm!');
      } else {
        throw Exception('Không thể thêm mục: ${response.body}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi: $e');
    }
  }

  Future<void> _addFromFridge(Map<String, dynamic> log, StateSetter setModalState) async {
    final foodName = log['foodName'] as String? ?? 'Thực phẩm không xác định';
    final newItem = {
      'id': '',
      'name': foodName,
      'quantity': 1,
      'foodId': log['foodId'],
    };

    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/add_shopping_list_item'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': newItem['name'],
          'createdBy': widget.userId,
          'quantity': newItem['quantity'],
          'foodId': newItem['foodId'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        newItem['id'] = data['itemId'];

        setState(() {
          _cartItems.add(newItem);
        });

        setModalState(() {});
        _showSuccessSnackBar('Đã thêm $foodName vào danh sách!');
      } else {
        throw Exception('Không thể thêm mục: ${response.body}');
      }
    } catch (e) {
      _showErrorSnackBar('Lỗi: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchStorageLogsForModal() async {
    try {
      final response = await http.get(
        Uri.parse('${Config.getNgrokUrl()}/get_sorted_storage_logs?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return List<Map<String, dynamic>>.from(data['logs'] ?? []);
      } else {
        throw Exception('Không thể lấy danh sách kho: ${response.body}');
      }
    } catch (e) {
      print('Lỗi khi lấy danh sách kho: $e');
      return [];
    }
  }

  Future<bool> _showDeleteConfirmDialog(String title, String content) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              Icon(Icons.warning_rounded, color: warningColor),
              const SizedBox(width: 8),
              Text(title),
            ],
          ),
          content: Text(content),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor)), // Sử dụng màu động
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: errorColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Xóa', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    ) ?? false;
  }

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: successColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: errorColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.all(16),
        action: SnackBarAction(
          label: 'Đóng',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: currentBackgroundColor, // Sử dụng màu động
      body: SafeArea(
        child: Column(
          children: [
            // Modern Header with animation
            SlideTransition(
              position: _headerSlideAnimation,
              child: Container(
                margin: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, accentColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -50,
                      top: -50,
                      child: Container(
                        width: 150,
                        height: 150,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -20,
                      bottom: -30,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.05),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          colors: [secondaryColor, Colors.white.withOpacity(0.3)],
                                          radius: 0.8,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.shopping_cart_rounded,
                                        color: Colors.white,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Danh sách mua sắm',
                                      style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '${_cartItems.length} mục',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.white.withOpacity(0.9),
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
            ),

            // Content
            Expanded(
              child: _isLoading
                  ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryColor),
                      strokeWidth: 3.0,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Đang tải danh sách...',
                      style: TextStyle(
                        color: currentTextSecondaryColor, // Sử dụng màu động
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              )
                  : _cartItems.isEmpty
                  ? _buildEmptyCart()
                  : _buildCartList(),
            ),
          ],
        ),
      ),
      floatingActionButton: _buildAddFab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _buildEmptyCart() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(40),
          padding: const EdgeInsets.all(40),
          decoration: BoxDecoration(
            color: currentSurfaceColor, // Sử dụng màu động
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05), // Sử dụng màu động
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor.withOpacity(0.2), accentColor.withOpacity(0.2)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(
                  Icons.shopping_cart_outlined,
                  size: 64,
                  color: primaryColor,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Danh sách mua sắm trống',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: currentTextPrimaryColor, // Sử dụng màu động
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Thêm mục vào danh sách bằng cách nhấn nút + ở dưới.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: currentTextSecondaryColor, // Sử dụng màu động
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _showAddItemDialog,
                icon: const Icon(Icons.add),
                label: const Text('Thêm mục đầu tiên'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCartList() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              itemCount: _cartItems.length,
              itemBuilder: (context, index) {
                return AnimatedBuilder(
                  animation: _slideAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, _slideAnimation.value * (index + 1)),
                      child: _buildCartItem(_cartItems[index], index),
                    );
                  },
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: currentSurfaceColor, // Sử dụng màu động
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
            ),
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _cartItems.isEmpty ? null : _placeOrder,
                    icon: const Icon(Icons.check_circle_outline, color: Colors.white),
                    label: const Text(
                      'Cập nhật danh sách mua sắm',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: successColor,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 4,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _cartItems.isEmpty ? null : _clearCart,
                    icon: Icon(Icons.delete_outline, color: errorColor),
                    label: Text(
                      'Xóa toàn bộ',
                      style: TextStyle(
                        color: errorColor,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: errorColor),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
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

  Widget _buildCartItem(Map<String, dynamic> item, int index) {
    final itemName = item['name'] ?? 'Mục không xác định';
    final quantity = item['quantity'] ?? 1;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: currentSurfaceColor, // Sử dụng màu động
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05), // Sử dụng màu động
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [accentColor.withOpacity(0.2), accentColor.withOpacity(0.1)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.shopping_basket_outlined,
                color: accentColor,
                size: 24,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    itemName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: currentTextPrimaryColor, // Sử dụng màu động
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Số lượng: $quantity',
                    style: TextStyle(
                      fontSize: 14,
                      color: currentTextSecondaryColor, // Sử dụng màu động
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120, // Constrain width to prevent overflow
              child: Container(
                decoration: BoxDecoration(
                  color: currentBackgroundColor.withOpacity(0.5), // Sử dụng màu động
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.remove, color: errorColor, size: 20),
                      onPressed: () => _updateQuantity(item['id'], quantity - 1),
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '$quantity',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: primaryColor,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add, color: successColor, size: 20),
                      onPressed: () => _updateQuantity(item['id'], quantity + 1),
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              decoration: BoxDecoration(
                color: errorColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: IconButton(
                icon: Icon(Icons.delete_outline, color: errorColor, size: 20),
                onPressed: () => _removeItem(item['id']),
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddFab() {
    return FloatingActionButton(
      onPressed: _showAddItemDialog,
      backgroundColor: primaryColor,
      foregroundColor: Colors.white,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Icon(Icons.add),
    );
  }
}