import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'config.dart'; // Nhập file config.dart chứa getNgrokUrl

class RecipeSuggestionScreen extends StatefulWidget {
  final List<Map<String, dynamic>> foodItems;
  final String userId;

  const RecipeSuggestionScreen({
    super.key,
    required this.foodItems,
    required this.userId,
  });

  @override
  _RecipeSuggestionScreenState createState() => _RecipeSuggestionScreenState();
}

class _RecipeSuggestionScreenState extends State<RecipeSuggestionScreen>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late List<Map<String, dynamic>> _processedFoodItems;
  List<Map<String, dynamic>> _recipes = [];
  List<Map<String, dynamic>> _cuisines = [];
  List<String> _selectedCuisines = ['Vietnamese']; // Default to Vietnamese
  bool _loading = false;
  String? _error;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<String> _selectedIngredients = [];
  final TextEditingController _cuisineController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _animationController.forward();
    _processedFoodItems = _processFoodItems();
    _fetchCuisines();
  }

  List<Map<String, dynamic>> _processFoodItems() {
    var processed = widget.foodItems.map((item) {
      print("Processing item: $item"); // Thêm log để kiểm tra dữ liệu
      final areaId = item['areaId'] as String? ?? '';
      final areaName = item['areaName'] ?? 'Khu vực không xác định';
      int expiryDays = 999;
      final expiryDateData = item['expiryDate'];
      if (expiryDateData != null) {
        try {
          DateTime? expiryDate;
          if (expiryDateData is Timestamp) {
            expiryDate = expiryDateData.toDate();
          } else if (expiryDateData is String) {
            expiryDate = DateTime.tryParse(expiryDateData) ??
                DateTime.tryParse(expiryDateData.split('.')[0]);
          } else if (expiryDateData is DateTime) {
            expiryDate = expiryDateData;
          }
          if (expiryDate != null) {
            expiryDays = expiryDate.difference(DateTime.now()).inDays;
          }
        } catch (e) {
          _error = 'Lỗi xử lý ngày hết hạn cho ${item['foodName']}: $e';
        }
      }
      return {
        'id': item['id'] as String? ?? '',
        'name': item['foodName'] as String? ?? 'Thực phẩm không xác định',
        'quantity': item['quantity'] ?? 0,
        'area': areaName,
        'expiryDays': expiryDays,
        'selected': false,
      };
    }).toList();
    print("Processed food items: $processed"); // Kiểm tra kết quả
    return processed;
  }

  Future<void> _fetchCuisines() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ngrokUrl = Config.getNgrokUrl();
      final response = await http.get(Uri.parse('$ngrokUrl/get_cuisines'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _cuisines = List<Map<String, dynamic>>.from(data['cuisines'] ?? []);
        });
      } else {
        throw Exception('Không thể lấy danh sách cuisine: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Đã xảy ra lỗi khi lấy danh sách cuisine: ${e.toString()}';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _addCuisine() async {
    if (_cuisineController.text.isEmpty) {
      setState(() {
        _error = 'Vui lòng nhập tên cuisine';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ngrokUrl = Config.getNgrokUrl();
      final response = await http.post(
        Uri.parse('$ngrokUrl/add_cuisine'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': _cuisineController.text}),
      );
      if (response.statusCode == 200) {
        _cuisineController.clear();
        await _fetchCuisines(); // Cập nhật danh sách sau khi thêm
      } else {
        throw Exception('Không thể thêm cuisine: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Đã xảy ra lỗi khi thêm cuisine: ${e.toString()}';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _deleteCuisine(String cuisineId) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ngrokUrl = Config.getNgrokUrl();
      final response = await http.delete(Uri.parse('$ngrokUrl/delete_cuisine/$cuisineId'));
      if (response.statusCode == 200) {
        setState(() {
          _selectedCuisines.removeWhere((cuisine) =>
              _cuisines.any((c) => c['id'] == cuisineId && c['name'] == cuisine));
          _cuisines.removeWhere((c) => c['id'] == cuisineId);
        });
      } else {
        throw Exception('Không thể xóa cuisine: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Đã xảy ra lỗi khi xóa cuisine: ${e.toString()}';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    _cuisineController.dispose();
    super.dispose();
  }

  Color _getStatusColor(int expiryDays) {
    if (expiryDays <= 0) return Colors.red;
    if (expiryDays <= 3) return Colors.orange;
    return Colors.green;
  }

  Future<void> _suggestRecipes() async {
    setState(() {
      _loading = true;
      _error = null;
      _selectedIngredients = _processedFoodItems
          .where((item) => item['selected'] == true)
          .map((item) => item['name'] as String)
          .toList();
      print("Selected ingredients: $_selectedIngredients"); // Log ingredients
      print("Selected cuisines: $_selectedCuisines"); // Log cuisines
    });

    try {
      final ngrokUrl = Config.getNgrokUrl();
      final response = await http.post(
        Uri.parse('$ngrokUrl/suggest_recipes'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': widget.userId,
          'ingredients': _selectedIngredients,
          'cuisines': _selectedCuisines,
          'language': 'vi',
        }),
      );
      print("API response status: ${response.statusCode}"); // Log status
      print("API response body: ${response.body}"); // Log body

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _recipes = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
          print("Fetched recipes: $_recipes"); // Log recipes
        });
      } else {
        throw Exception('Không thể lấy gợi ý công thức: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Đã xảy ra lỗi: ${e.toString()}';
        print("Error: $_error"); // Log error
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  // Hàm an toàn để lấy ngrokUrl (đã bỏ vì không cần thiết)

  void _showAddCuisineDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm loại ẩm thực'),
        content: TextField(
          controller: _cuisineController,
          decoration: const InputDecoration(
              hintText: 'Nhập tên ẩm thực (VD: Italian)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () {
              _addCuisine();
              Navigator.pop(context);
            },
            child: const Text('Thêm'),
          ),
        ],
      ),
    );
  }

  void _showRecipeDetails(Map<String, dynamic> recipe) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  recipe['title'] ?? 'Không có tiêu đề',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (recipe['imageUrl'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      recipe['imageUrl'],
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.broken_image, size: 100),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  'Thời gian chuẩn bị: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
                  style: const TextStyle(fontSize: 16),
                ),
                Text(
                  'Khẩu phần: ${recipe['servings'] ?? 'N/A'}',
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Nguyên liệu đã có:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                for (var ingredient in (recipe['ingredientsUsed'] ?? []))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text('• $ingredient'),
                  ),
                const SizedBox(height: 16),
                const Text(
                  'Nguyên liệu còn thiếu:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                for (var ingredient in (recipe['ingredientsMissing'] ?? []))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text('• $ingredient'),
                  ),
                const SizedBox(height: 16),
                const Text(
                  'Hướng dẫn:',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(recipe['instructions'] ?? 'Không có hướng dẫn'),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
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
                        'Gợi ý công thức',
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
                      onPressed: _showAddCuisineDialog,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _cuisines.isEmpty && _processedFoodItems.isEmpty
                    ? _buildEmptyScreen()
                    : FadeTransition(
                  opacity: _fadeAnimation,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Card(
                        elevation: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment:
                            CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.restaurant_menu,
                                      color: Color(0xFF1976D2)),
                                  SizedBox(width: 12),
                                  Text(
                                    'Loại ẩm thực',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF202124),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              if (_cuisines.isEmpty && !_loading)
                                const Text('Không có loại ẩm thực nào')
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: _cuisines.map((cuisine) {
                                    final isSelected =
                                    _selectedCuisines
                                        .contains(cuisine['name']);
                                    return ActionChip(
                                      label: Text(cuisine['vi_name'] ??
                                          cuisine['name']),
                                      backgroundColor: isSelected
                                          ? Colors.blue[100]
                                          : Colors.grey[200],
                                      onPressed: () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedCuisines.remove(
                                                cuisine['name']);
                                          } else {
                                            _selectedCuisines
                                                .add(cuisine['name']);
                                          }
                                        });
                                      },
                                      avatar: IconButton(
                                        icon: const Icon(Icons.delete,
                                            size: 18),
                                        onPressed: () =>
                                            _deleteCuisine(
                                                cuisine['id']),
                                      ),
                                    );
                                  }).toList(),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Card(
                        elevation: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment:
                            CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.fastfood,
                                      color: Color(0xFF1976D2)),
                                  SizedBox(width: 12),
                                  Text(
                                    'Thực phẩm hiện có',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF202124),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              ListView.builder(
                                shrinkWrap: true,
                                physics:
                                const NeverScrollableScrollPhysics(),
                                itemCount: _processedFoodItems.length,
                                itemBuilder: (context, index) {
                                  final item =
                                  _processedFoodItems[index];
                                  return ListTile(
                                    title: Text(item['name']),
                                    subtitle:
                                    Text('Khu vực: ${item['area']}'),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.circle,
                                          color: _getStatusColor(
                                              item['expiryDays']),
                                          size: 16,
                                        ),
                                        Checkbox(
                                          value: item['selected'],
                                          onChanged: (value) {
                                            setState(() {
                                              item['selected'] =
                                                  value ?? false;
                                            });
                                          },
                                          activeColor:
                                          const Color(0xFF1976D2),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _selectedIngredients
                                    .isEmpty &&
                                    _processedFoodItems.any(
                                            (item) =>
                                        item['selected'])
                                    ? _suggestRecipes
                                    : null,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 12, horizontal: 24),
                                  backgroundColor:
                                  const Color(0xFF00B294),
                                  shape: RoundedRectangleBorder(
                                    borderRadius:
                                    BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Tìm công thức',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      if (_recipes.isNotEmpty)
                        Card(
                          elevation: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment:
                              CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Công thức gợi ý',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF202124),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                ListView.builder(
                                  shrinkWrap: true,
                                  physics:
                                  const NeverScrollableScrollPhysics(),
                                  itemCount: _recipes.length,
                                  itemBuilder: (context, index) {
                                    final recipe = _recipes[index];
                                    return ListTile(
                                      leading: recipe['imageUrl'] !=
                                          null
                                          ? ClipRRect(
                                        borderRadius:
                                        BorderRadius
                                            .circular(8),
                                        child: Image.network(
                                          recipe['imageUrl'],
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context,
                                              error,
                                              stackTrace) =>
                                          const Icon(Icons
                                              .broken_image),
                                        ),
                                      )
                                          : const Icon(
                                          Icons.restaurant),
                                      title: Text(
                                        recipe['title'] ??
                                            'Không có tiêu đề',
                                        maxLines: 2,
                                        overflow:
                                        TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        'Thời gian: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
                                      ),
                                      onTap: () =>
                                          _showRecipeDetails(recipe),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyScreen() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.restaurant_menu, size: 64, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'Không có công thức hoặc thực phẩm',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          SizedBox(height: 8),
          Text(
            'Thêm loại ẩm thực hoặc thực phẩm bằng nút + ở trên.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}