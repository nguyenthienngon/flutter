import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'config.dart';
import 'favorite_recipes_screen.dart';

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

class _RecipeSuggestionScreenState extends State<RecipeSuggestionScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late List<Map<String, dynamic>> _processedFoodItems;
  List<Map<String, dynamic>> _recipes = [];
  List<Map<String, dynamic>> _cuisines = [];
  List<String> _selectedCuisines = [];
  List<String> _selectedTypes = []; // Khởi tạo là danh sách rỗng, tránh null
  bool _loading = false;
  String? _error;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<String> _selectedIngredients = [];
  final TextEditingController _cuisineController = TextEditingController();
  final String _ngrokUrl = Config.getNgrokUrl();

  final List<Map<String, String>> _recipeTypes = [
    {'en': 'main course', 'vi': 'Món chính'},
    {'en': 'appetizer', 'vi': 'Món khai vị'},
    {'en': 'dessert', 'vi': 'Món tráng miệng'},
    {'en': 'drink', 'vi': 'Đồ uống'},
  ];

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
    return widget.foodItems.map((item) {
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
            expiryDate = DateTime.tryParse(expiryDateData) ?? DateTime.tryParse(expiryDateData.split('.')[0]);
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
        'name': item['foodName'] as String? ?? 'Nguyên liệu không xác định',
        'quantity': item['quantity'] ?? 0,
        'area': areaName,
        'expiryDays': expiryDays,
        'selected': false,
      };
    }).toList();
  }

  Future<void> _fetchCuisines() async {
    setState(() => _loading = true);
    try {
      final response = await http.get(Uri.parse('$_ngrokUrl/get_cuisines'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _cuisines = List<Map<String, dynamic>>.from(data['cuisines'] ?? []));
      } else {
        throw Exception('Lỗi khi tải danh sách ẩm thực: ${response.body}');
      }
    } catch (e) {
      setState(() => _error = 'Lỗi khi tải danh sách ẩm thực: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _addCuisine() async {
    if (_cuisineController.text.isEmpty) {
      setState(() => _error = 'Vui lòng nhập tên ẩm thực');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
      return;
    }
    setState(() => _loading = true);
    try {
      final response = await http.post(
        Uri.parse('$_ngrokUrl/add_cuisine'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': _cuisineController.text}),
      );
      if (response.statusCode == 200) {
        _cuisineController.clear();
        await _fetchCuisines();
      } else {
        throw Exception('Lỗi khi thêm ẩm thực: ${response.body}');
      }
    } catch (e) {
      setState(() => _error = 'Lỗi khi thêm ẩm thực: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _deleteCuisine(String cuisineId) async {
    setState(() => _loading = true);
    try {
      final response = await http.delete(Uri.parse('$_ngrokUrl/delete_cuisine/$cuisineId'));
      if (response.statusCode == 200) {
        setState(() {
          _cuisines.removeWhere((c) => c['id'] == cuisineId);
          _selectedCuisines.removeWhere((cuisine) => _cuisines.any((c) => c['id'] == cuisineId && c['name'] == cuisine));
        });
      } else {
        throw Exception('Lỗi khi xóa ẩm thực: ${response.body}');
      }
    } catch (e) {
      setState(() => _error = 'Lỗi khi xóa ẩm thực: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _suggestRecipes() async {
    if (!_processedFoodItems.any((item) => item['selected'])) {
      setState(() {
        _error = 'Vui lòng chọn ít nhất một nguyên liệu.';
        _recipes = [];
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _selectedIngredients = _processedFoodItems.where((item) => item['selected'] == true).map((item) => item['name'] as String).toList();
    });

    print('Gửi yêu cầu gợi ý công thức với nguyên liệu: $_selectedIngredients, ẩm thực: $_selectedCuisines, loại: $_selectedTypes');

    try {
      final payload = {
        'userId': widget.userId,
        'ingredients': _selectedIngredients,
        'cuisines': _selectedCuisines,
        'type': _selectedTypes, // Gửi danh sách loại
      };

      final response = await http.post(
        Uri.parse('$_ngrokUrl/suggest_recipes'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      print('Mã trạng thái phản hồi: ${response.statusCode}, nội dung: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final recipes = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
        // Kiểm tra trạng thái yêu thích cho mỗi công thức
        final updatedRecipes = await Future.wait(recipes.map((recipe) async {
          final isFav = await _isFavorite(recipe['recipeId']);
          recipe['isFavorite'] = isFav; // Cập nhật trạng thái yêu thích
          return recipe;
        }));
        setState(() {
          _recipes = updatedRecipes;
        });
        print('Công thức nhận được: $_recipes');
      } else {
        throw Exception('Lỗi khi lấy công thức: ${response.body}');
      }
    } catch (e) {
      print('Lỗi khi gợi ý công thức: $e');
      setState(() => _error = 'Lỗi khi gợi ý công thức: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
    } finally {
      setState(() => _loading = false);
      print('Trạng thái tải đã đặt thành false');
    }
  }

  Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
    setState(() => _loading = true);
    try {
      if (isFavorite) {
        final response = await http.post(
          Uri.parse('$_ngrokUrl/delete_favorite_recipe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'favorite_recipe_id': recipeId,
            'userId': widget.userId,
          }),
        );
        if (response.statusCode == 200) {
          setState(() {
            final recipeIndex = _recipes.indexWhere((r) => r['recipeId'] == recipeId);
            if (recipeIndex != -1) {
              _recipes[recipeIndex]['isFavorite'] = false;
            }
          });
        } else {
          throw Exception('Lỗi khi xóa công thức yêu thích: ${response.body}');
        }
      } else {
        final recipeIndex = _recipes.indexWhere((r) => r['recipeId'] == recipeId);
        if (recipeIndex != -1) {
          final recipe = _recipes[recipeIndex];
          final response = await http.post(
            Uri.parse('$_ngrokUrl/add_favorite_recipe'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'userId': widget.userId,
              'recipeId': recipeId,
              'recipe': recipe,
            }),
          );
          if (response.statusCode == 200) {
            setState(() {
              _recipes[recipeIndex]['isFavorite'] = true;
            });
          } else {
            throw Exception('Lỗi khi thêm công thức yêu thích: ${response.body}');
          }
        }
      }
    } catch (e) {
      setState(() => _error = 'Lỗi khi cập nhật công thức yêu thích: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_error!)));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<bool> _isFavorite(String recipeId) async {
    try {
      final response = await http.get(Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final favorites = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
        return favorites.any((r) => r['recipeId'] == recipeId);
      }
      return false;
    } catch (e) {
      print('Lỗi khi kiểm tra trạng thái yêu thích: $e');
      return false;
    }
  }

  void _showAddCuisineDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Thêm Ẩm Thực'),
        content: TextField(
          controller: _cuisineController,
          decoration: const InputDecoration(hintText: 'Nhập tên ẩm thực (ví dụ: Ý)'),
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

  void _showDeleteCuisineDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xóa Ẩm Thực'),
        content: _cuisines.isEmpty
            ? const Text('Không có ẩm thực nào để xóa.')
            : SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _cuisines.map((cuisine) {
              return ListTile(
                title: Text(cuisine['name']),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () {
                    Navigator.pop(context);
                    _deleteCuisine(cuisine['id']);
                  },
                ),
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
  }

  void _showCuisineOptions(BuildContext context) {
    showMenu(
      context: context,
      position: const RelativeRect.fromLTRB(100, 100, 0, 0),
      items: [
        const PopupMenuItem(
          value: 'add',
          child: Row(
            children: [
              Icon(Icons.add),
              SizedBox(width: 8),
              Text('Thêm Ẩm Thực'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete),
              SizedBox(width: 8),
              Text('Xóa Ẩm Thực'),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'add') {
        _showAddCuisineDialog();
      } else if (value == 'delete') {
        _showDeleteCuisineDialog();
      }
    });
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
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 100),
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
                const Text('Nguyên liệu có sẵn:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (var ingredient in (recipe['ingredientsUsed'] ?? []))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text('• $ingredient'),
                  ),
                const SizedBox(height: 16),
                const Text('Nguyên liệu còn thiếu:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                for (var ingredient in (recipe['ingredientsMissing'] ?? []))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text('• $ingredient'),
                  ),
                const SizedBox(height: 16),
                const Text('Hướng dẫn:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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

  Color _getStatusColor(int expiryDays) {
    if (expiryDays <= 0) return Colors.red;
    if (expiryDays <= 3) return Colors.orange;
    return Colors.green;
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
                        'Gợi Ý Công Thức',
                        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.favorite, color: Colors.white),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => FavoriteRecipesScreen(userId: widget.userId),
                          ),
                        );
                      },
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Row(
                                    children: [
                                      Icon(Icons.restaurant_menu, color: Color(0xFF1976D2)),
                                      SizedBox(width: 12),
                                      Text(
                                        'Ẩm Thực',
                                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF202124)),
                                      ),
                                    ],
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert, color: Color(0xFF1976D2)),
                                    onPressed: () => _showCuisineOptions(context),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Chọn loại ẩm thực hoặc để trống để gợi ý từ mọi phong cách.',
                                style: TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                              const SizedBox(height: 8),
                              if (_cuisines.isEmpty && !_loading)
                                const Text('Không có ẩm thực nào')
                              else
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: _cuisines.map((cuisine) {
                                    final isSelected = _selectedCuisines.contains(cuisine['name']);
                                    return ActionChip(
                                      label: Text(cuisine['name']),
                                      backgroundColor: isSelected ? Colors.blue[100] : Colors.grey[200],
                                      onPressed: () {
                                        setState(() {
                                          if (isSelected) {
                                            _selectedCuisines.remove(cuisine['name']);
                                          } else {
                                            _selectedCuisines.add(cuisine['name']);
                                          }
                                        });
                                      },
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.category, color: Color(0xFF1976D2)),
                                  SizedBox(width: 12),
                                  Text(
                                    'Loại Công Thức',
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF202124)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Chọn loại công thức hoặc để trống để tìm tất cả.',
                                style: TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: _recipeTypes.map((type) {
                                  final isSelected = _selectedTypes.contains(type['en']);
                                  return ActionChip(
                                    label: Text(type['vi']!),
                                    backgroundColor: isSelected ? Colors.blue[100] : Colors.grey[200],
                                    onPressed: () {
                                      setState(() {
                                        if (isSelected) {
                                          _selectedTypes.remove(type['en']);
                                        } else {
                                          _selectedTypes.add(type['en']!);
                                        }
                                      });
                                    },
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.fastfood, color: Color(0xFF1976D2)),
                                  SizedBox(width: 12),
                                  Text(
                                    'Nguyên Liệu Có Sẵn',
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF202124)),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _processedFoodItems.length,
                                itemBuilder: (context, index) {
                                  final item = _processedFoodItems[index];
                                  return ListTile(
                                    title: Text(item['name']),
                                    subtitle: Text('Khu vực: ${item['area']}'),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.circle,
                                          color: _getStatusColor(item['expiryDays']),
                                          size: 16,
                                        ),
                                        Checkbox(
                                          value: item['selected'],
                                          onChanged: (value) {
                                            setState(() {
                                              item['selected'] = value ?? false;
                                            });
                                          },
                                          activeColor: const Color(0xFF1976D2),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _suggestRecipes,
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                                  backgroundColor: const Color(0xFF00B294),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text(
                                  'Tìm Công Thức',
                                  style: TextStyle(fontSize: 16, color: Colors.white),
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
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Công Thức Gợi Ý',
                                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF202124)),
                                ),
                                const SizedBox(height: 16),
                                ListView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  itemCount: _recipes.length,
                                  itemBuilder: (context, index) {
                                    final recipe = _recipes[index];
                                    return ListTile(
                                      leading: recipe['imageUrl'] != null
                                          ? ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: Image.network(
                                          recipe['imageUrl'],
                                          width: 50,
                                          height: 50,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
                                        ),
                                      )
                                          : const Icon(Icons.restaurant),
                                      title: Text(
                                        recipe['title'] ?? 'Không có tiêu đề',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        'Thời gian: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
                                      ),
                                      trailing: FutureBuilder<bool>(
                                        future: _isFavorite(recipe['recipeId']),
                                        builder: (context, snapshot) {
                                          if (!snapshot.hasData) return const SizedBox.shrink();
                                          final isFavorite = snapshot.data!;
                                          return Padding(
                                            padding: const EdgeInsets.only(right: 4.0),
                                            child: IconButton(
                                              icon: Icon(
                                                isFavorite ? Icons.favorite : Icons.favorite_border,
                                                color: isFavorite ? Colors.red : null,
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  recipe['isFavorite'] = !isFavorite;
                                                });
                                                _toggleFavorite(recipe['recipeId'], isFavorite);
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                      onTap: () => _showRecipeDetails(recipe),
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
            'Không có công thức hoặc nguyên liệu',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          SizedBox(height: 8),
          Text(
            'Thêm ẩm thực hoặc nguyên liệu bằng menu ở trên.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _cuisineController.dispose();
    super.dispose();
  }
}