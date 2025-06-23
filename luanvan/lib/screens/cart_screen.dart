import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config.dart';

class CartScreen extends StatefulWidget {
  final String userId;

  const CartScreen({
    super.key,
    required this.userId,
  });

  @override
  _CartScreenState createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late List<Map<String, dynamic>> _cartItems;
  final TextEditingController _manualInputController = TextEditingController();
  final Map<String, String> _foodNameCache = {}; // Cache tên thực phẩm
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _cartItems = [];
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
    _fetchCartItems(); // Lấy danh sách mua sắm dựa trên userId
  }

  @override
  void dispose() {
    _animationController.dispose();
    _manualInputController.dispose();
    super.dispose();
  }

  Future<void> _fetchCartItems() async {
    setState(() {
      _isLoading = true;
    });
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
        await _fetchFoodNamesForItems(); // Lấy tên thực phẩm nếu cần
      } else {
        throw Exception('Không thể lấy danh sách mua sắm: ${response.body}');
      }
    } catch (e) {
      print('Lỗi khi lấy danh sách mua sắm: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchFoodNamesForItems() async {
    final foodIds = _cartItems.where((item) => item['foodId'] != null && !item.containsKey('name')).map((item) => item['foodId'] as String).toList();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
      setState(() {
        final index = _cartItems.indexWhere((item) => item['id'] == itemId);
        if (index >= 0) {
          _cartItems[index]['quantity'] = (_cartItems[index]['quantity'] ?? 1) + (newQuantity < (_cartItems[index]['quantity'] ?? 1) ? 1 : -1);
        }
      });
    }
  }

  Future<void> _removeItem(String itemId) async {
    setState(() {
      _cartItems.removeWhere((item) => item['id'] == itemId);
    });

    try {
      final response = await http.delete(
        Uri.parse('${Config.getNgrokUrl()}/delete_shopping_list_item/$itemId?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode != 200) {
        throw Exception('Không thể xóa mục: ${response.body}');
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xóa khỏi danh sách mua sắm!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
      setState(() {
        _cartItems.add({'id': itemId, 'name': 'Không xác định', 'quantity': 1});
      });
    }
  }

  Future<void> _clearCart() async {
    setState(() {
      _cartItems.clear();
    });

    try {
      for (var item in List.from(_cartItems)) {
        await http.delete(
          Uri.parse('${Config.getNgrokUrl()}/delete_shopping_list_item/${item['id']}?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã xóa toàn bộ danh sách mua sắm!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e')),
      );
      await _fetchCartItems(); // Lấy lại danh sách nếu xóa thất bại
    }
  }

  Future<void> _placeOrder() async {
    if (_cartItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Danh sách mua sắm trống!')),
      );
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('${Config.getNgrokUrl()}/place_order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': widget.userId,
          'items': _cartItems,
          'timestamp': '',
          'status': 'pending',
        }),
      );

      if (response.statusCode == 200) {
        setState(() {
          _cartItems.clear();
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Danh sách mua sắm được cập nhật thành công!'),
            backgroundColor: Color(0xFF00B294),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
          ),
        );
      } else {
        throw Exception('Không thể cập nhật danh sách mua sắm: ${response.body}');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi khi cập nhật danh sách mua sắm: $e')),
      );
    }
  }

  void _showAddItemDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Thêm vào danh sách mua sắm',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _manualInputController,
                decoration: const InputDecoration(
                  labelText: 'Nhập tên mục',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  if (_manualInputController.text.trim().isNotEmpty) {
                    final itemId = DateTime.now().toString();
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
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Đã thêm vào danh sách mua sắm!')),
                        );
                      } else {
                        throw Exception('Không thể thêm mục: ${response.body}');
                      }
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Lỗi: $e')),
                      );
                    }
                  }
                },
                child: const Text('Thêm thủ công'),
              ),
              const SizedBox(height: 16),
              const Text(
                'Hoặc chọn từ tủ lạnh:',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : FutureBuilder<List<Map<String, dynamic>>>(
                future: _fetchStorageLogsForModal(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const Center(child: Text('Lỗi khi tải danh sách kho.'));
                  }
                  final storageLogs = snapshot.data ?? [];
                  return storageLogs.isEmpty
                      ? const Center(child: Text('Không có thực phẩm trong tủ lạnh.'))
                      : Container(
                    height: 200,
                    child: ListView.builder(
                      itemCount: storageLogs.length,
                      itemBuilder: (context, index) {
                        final log = storageLogs[index];
                        final foodName = log['foodName'] as String? ?? 'Thực phẩm không xác định';
                        return ListTile(
                          title: Text(foodName),
                          trailing: IconButton(
                            icon: const Icon(Icons.add, color: Colors.green),
                            onPressed: () async {
                              final itemId = DateTime.now().toString();
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
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Đã thêm vào danh sách mua sắm!')),
                                  );
                                } else {
                                  throw Exception('Không thể thêm mục: ${response.body}');
                                }
                              } catch (e) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Lỗi: $e')),
                                );
                              }
                            },
                          ),
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE3F2FD), Color(0xFFE8F5E8), Colors.white],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: [0.0, 0.3, 1.0],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF1976D2), Color(0xFF388E3C)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(32),
                    bottomRight: Radius.circular(32),
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Expanded(
                      child: Text(
                        'Danh sách mua sắm',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle, color: Colors.white),
                      onPressed: _showAddItemDialog,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _cartItems.isEmpty
                    ? _buildEmptyCart()
                    : FadeTransition(
                  opacity: _fadeAnimation,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _cartItems.length + 1,
                    itemBuilder: (context, index) {
                      if (index < _cartItems.length) {
                        final item = _cartItems[index];
                        return Card(
                          elevation: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: ListTile(
                            title: Text(item['name'] ?? 'Mục không xác định'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.remove, color: Colors.red),
                                  onPressed: () => _updateQuantity(item['id'], (item['quantity'] ?? 1) - 1),
                                ),
                                Text('${item['quantity'] ?? 1}'),
                                IconButton(
                                  icon: const Icon(Icons.add, color: Colors.green),
                                  onPressed: () => _updateQuantity(item['id'], (item['quantity'] ?? 1) + 1),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => _removeItem(item['id']),
                                ),
                              ],
                            ),
                          ),
                        );
                      } else {
                        return Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              ElevatedButton(
                                onPressed: _placeOrder,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF00B294),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text('Cập nhật danh sách mua sắm'),
                              ),
                              const SizedBox(height: 8),
                              ElevatedButton(
                                onPressed: _clearCart,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text('Xóa toàn bộ'),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyCart() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shopping_cart, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Danh sách mua sắm trống',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          SizedBox(height: 8),
          Text(
            'Thêm mục vào danh sách bằng cách nhấn nút + ở trên.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}