import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'config.dart';

class FavoriteRecipesScreen extends StatefulWidget {
  final String userId;
  final bool isDarkMode;

  const FavoriteRecipesScreen({
    super.key,
    required this.userId,
    required this.isDarkMode,
  });

  @override
  _FavoriteRecipesScreenState createState() => _FavoriteRecipesScreenState();
}

class _FavoriteRecipesScreenState extends State<FavoriteRecipesScreen> with TickerProviderStateMixin {
  List<Map<String, dynamic>> _favoriteRecipes = [];
  bool _isLoading = false;
  String? _error;
  final String _ngrokUrl = Config.getNgrokUrl();
  final Logger _logger = Logger();

  late AnimationController _animationController;
  late AnimationController _headerController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<Offset> _headerSlideAnimation;

  Color get currentBackgroundColor => widget.isDarkMode ? const Color(0xFF121212) : const Color(0xFFE6F7FF);
  Color get currentSurfaceColor => widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white;
  Color get currentTextPrimaryColor => widget.isDarkMode ? const Color(0xFFE0E0E0) : const Color(0xFF202124);
  Color get currentTextSecondaryColor => widget.isDarkMode ? const Color(0xFFB0B0B0) : const Color(0xFF5F6368);

  final Color primaryColor = const Color(0xFF0078D7);
  final Color accentColor = const Color(0xFF00B294);
  final Color errorColor = const Color(0xFFE74C3C);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color secondaryColor = const Color(0xFF50E3C2);

  @override
  void initState() {
    super.initState();
    _setupAnimations();
    _loadFavoriteRecipes();
  }

  void _setupAnimations() {
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _headerController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOut));
    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _headerController, curve: Curves.easeOut));

    _headerController.forward();
    _animationController.forward();
  }

  Future<void> _loadFavoriteRecipes() async {
    setState(() => _isLoading = true);

    try {
      _logger.i('Gửi yêu cầu tới: $_ngrokUrl/get_favorite_recipes?userId=${widget.userId}');
      final response = await http.get(
        Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      _logger.i('Phản hồi HTTP: status=${response.statusCode}, body=${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _logger.i('Dữ liệu JSON: $data');

        final List<Map<String, dynamic>> recipes = List<Map<String, dynamic>>.from(data['favoriteRecipes'] ?? []).map((recipe) {
          return {
            ...recipe,
            'image': recipe['imageUrl'] ?? '',
            'isFavorite': true,
            'favoritedDate': recipe['createdAt']?.toString() ?? DateTime.now().toIso8601String(),
            'favoriteRecipeId': recipe['id'] ?? 'unknown_${recipe['recipeId']}',
            'instructions': recipe['instructions'] ?? 'Không có hướng dẫn chi tiết',
            'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
            'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
            'readyInMinutes': recipe['readyInMinutes'] ?? 0,
            'timeSlot': recipe['timeSlot'] ?? 'day',
            'nutrition': recipe['nutrition'] ?? [],
            'diets': recipe['diets'] ?? [],
          };
        }).toList();

        recipes.sort((a, b) {
          final dateA = DateTime.tryParse(a['favoritedDate'] ?? '') ?? DateTime.now();
          final dateB = DateTime.tryParse(b['favoritedDate'] ?? '') ?? DateTime.now();
          return dateB.compareTo(dateA);
        });

        setState(() {
          _favoriteRecipes = recipes;
          _error = null;
        });

        _logger.i('Đã tải ${_favoriteRecipes.length} công thức yêu thích');
        if (_favoriteRecipes.isNotEmpty) {
          _showSuccessSnackBar('Đã tải ${_favoriteRecipes.length} công thức yêu thích!');
        } else {
          _logger.w('Không có công thức yêu thích nào được trả về');
          _showErrorSnackBar('Không có công thức yêu thích nào!');
        }
      } else {
        throw Exception('Không thể tải công thức yêu thích: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi tải công thức yêu thích: $e', error: e, stackTrace: stackTrace);
      setState(() {
        _error = 'Lỗi khi tải công thức yêu thích: $e';
        _showErrorSnackBar(_error!);
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteFavoriteRecipe(String favoriteRecipeId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: currentSurfaceColor,
        title: Row(
          children: [
            Icon(Icons.delete_outline, color: errorColor, size: 20),
            const SizedBox(width: 8),
            Text('Xác nhận xóa', style: TextStyle(color: currentTextPrimaryColor, fontSize: 16)),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa công thức này khỏi danh sách yêu thích?',
          style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
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
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Xóa', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isLoading = true);

    try {
      final response = await http.delete(
        Uri.parse('$_ngrokUrl/delete_favorite_recipe/$favoriteRecipeId?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _favoriteRecipes.removeWhere((r) => r['favoriteRecipeId'] == favoriteRecipeId);
          _error = null;
        });
        _showSuccessSnackBar('Đã xóa công thức khỏi danh sách yêu thích!');
      } else {
        throw Exception('Không thể xóa công thức yêu thích: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi xóa công thức yêu thích: $e', error: e, stackTrace: stackTrace);
      setState(() {
        _error = 'Lỗi khi xóa công thức yêu thích: $e';
        _showErrorSnackBar(_error!);
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateFavoriteRecipe(String favoriteRecipeId, Map<String, dynamic> updatedRecipe) async {
    setState(() => _isLoading = true);

    try {
      final response = await http.put(
        Uri.parse('$_ngrokUrl/update_favorite_recipe/$favoriteRecipeId?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'title': updatedRecipe['title'],
          'instructions': updatedRecipe['instructions'],
          'image': updatedRecipe['image'],
          'ingredientsUsed': updatedRecipe['ingredientsUsed'] ?? [],
          'ingredientsMissing': updatedRecipe['ingredientsMissing'] ?? [],
          'readyInMinutes': updatedRecipe['readyInMinutes'] ?? 0,
          'timeSlot': updatedRecipe['timeSlot'] ?? 'day',
          'nutrition': updatedRecipe['nutrition'] ?? [],
          'diets': updatedRecipe['diets'] ?? [],
        }),
      );

      if (response.statusCode == 200) {
        await _loadFavoriteRecipes();
        _showSuccessSnackBar('Đã cập nhật công thức thành công!');
      } else {
        throw Exception('Không thể cập nhật công thức yêu thích: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi cập nhật công thức yêu thích: $e', error: e, stackTrace: stackTrace);
      setState(() {
        _error = 'Lỗi khi cập nhật công thức yêu thích: $e';
        _showErrorSnackBar(_error!);
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showEditRecipeDialog(Map<String, dynamic> recipe, String favoriteRecipeId) {
    final TextEditingController titleController = TextEditingController(text: recipe['title'] ?? 'Không có tiêu đề');
    final TextEditingController instructionsController = TextEditingController(text: recipe['instructions'] ?? 'Không có hướng dẫn');

    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: currentSurfaceColor,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
            maxWidth: MediaQuery.of(context).size.width * 0.9,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [primaryColor, accentColor]),
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.edit, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Chỉnh sửa công thức',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: titleController,
                        decoration: InputDecoration(
                          labelText: 'Tiêu đề công thức',
                          labelStyle: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
                          prefixIcon: Icon(Icons.title, color: primaryColor, size: 20),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: primaryColor, width: 2),
                          ),
                        ),
                        style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                      ),
                      const SizedBox(height: 12),
                      if (recipe['image'] != null && recipe['image'].isNotEmpty)
                        Container(
                          height: MediaQuery.of(context).size.height * 0.18,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.1),
                                blurRadius: 6,
                                offset: const Offset(0, 3),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              recipe['image'],
                              fit: BoxFit.cover,
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                return Center(
                                    child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(primaryColor)));
                              },
                              errorBuilder: (context, error, stackTrace) => Container(
                                decoration: BoxDecoration(
                                  color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Center(
                                  child: Icon(Icons.broken_image,
                                      size: 36, color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[600]),
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: instructionsController,
                        maxLines: 4,
                        decoration: InputDecoration(
                          labelText: 'Hướng dẫn nấu ăn',
                          labelStyle: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
                          prefixIcon: Icon(Icons.description, color: primaryColor, size: 20),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(color: primaryColor, width: 2),
                          ),
                          alignLabelWithHint: true,
                        ),
                        style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text('Hủy', style: TextStyle(color: currentTextSecondaryColor, fontSize: 14)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final updatedRecipe = {
                          'title': titleController.text,
                          'instructions': instructionsController.text,
                          'image': recipe['image'],
                          'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
                          'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
                          'readyInMinutes': recipe['readyInMinutes'] ?? 0,
                          'timeSlot': recipe['timeSlot'] ?? 'day',
                          'nutrition': recipe['nutrition'] ?? [],
                          'diets': recipe['diets'] ?? [],
                          'favoritedDate': recipe['favoritedDate'],
                        };
                        _updateFavoriteRecipe(favoriteRecipeId, updatedRecipe);
                        Navigator.pop(context);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accentColor,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('Lưu thay đổi',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showRecipeDetails(Map<String, dynamic> recipe) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: currentSurfaceColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          recipe['title'] ?? 'Không có tiêu đề',
                          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.edit, color: primaryColor, size: 18),
                        onPressed: () => _showEditRecipeDialog(recipe, recipe['favoriteRecipeId']),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Đã lưu vào: ${DateFormat('dd/MM/yyyy HH:mm').format(DateTime.tryParse(recipe['favoritedDate'] ?? '') ?? DateTime.now())}',
                    style: TextStyle(fontSize: 12, color: currentTextSecondaryColor),
                  ),
                  const SizedBox(height: 12),
                  if (recipe['image'] != null && recipe['image'].isNotEmpty)
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 6, offset: const Offset(0, 3)),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          recipe['image'],
                          height: MediaQuery.of(context).size.height * 0.18,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            height: MediaQuery.of(context).size.height * 0.18,
                            color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                            child: Icon(Icons.broken_image,
                                size: 36, color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[600]),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.access_time, color: primaryColor, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Thời gian: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primaryColor),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Icon(Icons.schedule, color: primaryColor, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              'Thời điểm: ${recipe['timeSlot'] == 'morning' ? 'Sáng' : recipe['timeSlot'] == 'afternoon' ? 'Trưa' : 'Tối'}',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primaryColor),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (recipe['diets'] != null && (recipe['diets'] as List).isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chế độ ăn phù hợp',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: (recipe['diets'] as List).map((diet) => Chip(
                            label: Text(diet.toString(),
                                style: TextStyle(color: currentTextPrimaryColor, fontSize: 11)),
                            backgroundColor: primaryColor.withOpacity(0.1),
                            side: BorderSide(color: primaryColor.withOpacity(0.3)),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          )).toList(),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  if (recipe['nutrition'] != null && (recipe['nutrition'] as List).isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Thông tin dinh dưỡng',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          height: MediaQuery.of(context).size.height * 0.18,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
                          ),
                          child: _buildNutritionChart(recipe['nutrition']),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  _buildIngredientSection(
                    'Nguyên liệu',
                    [
                      ...(recipe['ingredientsUsed'] as List<dynamic>? ?? []).map((e) => ({
                        'text': e['name'] != null && e['amount'] != null && e['unit'] != null
                            ? '${e['name']} (${e['amount']} ${e['unit']})'
                            : e['name']?.toString() ?? 'Unknown',
                        'isMissing': false,
                      })),
                      ...(recipe['ingredientsMissing'] as List<dynamic>? ?? []).map((e) => ({
                        'text': e['name'] != null && e['amount'] != null && e['unit'] != null
                            ? '${e['name']} (${e['amount']} ${e['unit']})'
                            : e['name']?.toString() ?? 'Unknown',
                        'isMissing': true,
                      })),
                    ],
                    primaryColor,
                    Icons.restaurant_menu,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Hướng dẫn',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
                    ),
                    child: Text(
                      recipe['instructions'] ?? 'Không có hướng dẫn chi tiết',
                      style: TextStyle(fontSize: 12, height: 1.5, color: currentTextPrimaryColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNutritionChart(List<dynamic> nutrients) {
    final keyNutrients = ['Calories', 'Fat', 'Carbohydrates', 'Protein'];
    final filteredNutrients = nutrients.where((n) => n is Map && keyNutrients.contains(n['name'])).toList();
    final nutrientData = {
      'Calories': filteredNutrients.firstWhere((n) => n['name'] == 'Calories', orElse: () => {'amount': 0.0, 'unit': 'kcal'})['amount']?.toDouble() ?? 0.0,
      'Fat': filteredNutrients.firstWhere((n) => n['name'] == 'Fat', orElse: () => {'amount': 0.0, 'unit': 'g'})['amount']?.toDouble() ?? 0.0,
      'Carbohydrates': filteredNutrients.firstWhere((n) => n['name'] == 'Carbohydrates', orElse: () => {'amount': 0.0, 'unit': 'g'})['amount']?.toDouble() ?? 0.0,
      'Protein': filteredNutrients.firstWhere((n) => n['name'] == 'Protein', orElse: () => {'amount': 0.0, 'unit': 'g'})['amount']?.toDouble() ?? 0.0,
    };

    if (nutrientData.values.every((value) => value == 0.0)) {
      return Center(
          child: Text('Không có dữ liệu dinh dưỡng', style: TextStyle(color: currentTextSecondaryColor, fontSize: 12)));
    }

    return PieChart(
      PieChartData(
        sections: [
          PieChartSectionData(
            value: nutrientData['Calories']!,
            color: const Color(0xFF36A2EB),
            title: 'Calories',
            radius: 40,
            titleStyle: TextStyle(fontSize: 10, color: widget.isDarkMode ? Colors.white : Colors.black),
          ),
          PieChartSectionData(
            value: nutrientData['Fat']!,
            color: const Color(0xFFFFCE56),
            title: 'Fat',
            radius: 40,
            titleStyle: TextStyle(fontSize: 10, color: widget.isDarkMode ? Colors.white : Colors.black),
          ),
          PieChartSectionData(
            value: nutrientData['Carbohydrates']!,
            color: const Color(0xFFFF6384),
            title: 'Carbs',
            radius: 40,
            titleStyle: TextStyle(fontSize: 10, color: widget.isDarkMode ? Colors.white : Colors.black),
          ),
          PieChartSectionData(
            value: nutrientData['Protein']!,
            color: const Color(0xFF4BC0C0),
            title: 'Protein',
            radius: 40,
            titleStyle: TextStyle(fontSize: 10, color: widget.isDarkMode ? Colors.white : Colors.black),
          ),
        ],
        sectionsSpace: 2,
        centerSpaceRadius: 20,
        pieTouchData: PieTouchData(
          enabled: true,
          touchCallback: (FlTouchEvent event, pieTouchResponse) {
            // Optional: Handle touch interactions
          },
        ),
      ),
    );
  }

  Widget _buildIngredientSection(String title, List<Map<String, dynamic>> ingredients, Color color, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (ingredients.isEmpty)
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Không có nguyên liệu', style: TextStyle(color: currentTextSecondaryColor, fontSize: 12)),
          )
        else
          ...ingredients.map((ingredient) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: ingredient['isMissing'] ? warningColor.withOpacity(0.1) : successColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: ingredient['isMissing'] ? warningColor.withOpacity(0.3) : successColor.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(
                  ingredient['isMissing'] ? Icons.warning : Icons.check_circle,
                  color: ingredient['isMissing'] ? warningColor : successColor,
                  size: 12,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    ingredient['text'],
                    style: TextStyle(
                      color: currentTextPrimaryColor,
                      fontSize: 12,
                      fontStyle: ingredient['isMissing'] ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                ),
              ],
            ),
          )),
      ],
    );
  }

  Widget _buildSkeletonLoader() {
    return Column(
      children: List.generate(
        3,
            (index) => Container(
          margin: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
          decoration: BoxDecoration(
            color: currentSurfaceColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.08), blurRadius: 10, offset: const Offset(0, 4)),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: double.infinity,
                        height: 12,
                        color: widget.isDarkMode ? Colors.grey[600] : Colors.grey[300],
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 80,
                        height: 10,
                        color: widget.isDarkMode ? Colors.grey[600] : Colors.grey[300],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: currentSurfaceColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [primaryColor.withOpacity(0.2), primaryColor.withOpacity(0.1)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                Icons.favorite_border,
                size: 48,
                color: primaryColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Chưa có công thức yêu thích',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Thêm công thức yêu thích từ màn hình gợi ý\nđể lưu lại và xem bất cứ lúc nào!',
              style: TextStyle(
                fontSize: 12,
                color: currentTextSecondaryColor,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(
                Icons.explore,
                color: Colors.white,
                size: 16,
              ),
              label: const Text(
                'Khám phá công thức',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: accentColor,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  Widget _buildRecipeCard(Map<String, dynamic> recipe, int index) {
    final date = DateTime.tryParse(recipe['favoritedDate'] ?? '') ?? DateTime.now();
    final formattedDate = DateFormat('dd/MM/yyyy').format(date);

    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        final animationValue = Curves.easeOutBack.transform((_animationController.value - (index * 0.1)).clamp(0.0, 1.0));
        return Transform.translate(
          offset: Offset(0, 40 * (1 - animationValue)),
          child: Opacity(
            opacity: animationValue.clamp(0.0, 1.0),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12, left: 16, right: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.08), blurRadius: 10, offset: const Offset(0, 4)),
                ],
              ),
              child: Card(
                elevation: 0,
                margin: EdgeInsets.zero,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                color: currentSurfaceColor,
                child: InkWell(
                  onTap: () => _showRecipeDetails(recipe),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Đã lưu vào: $formattedDate',
                          style: TextStyle(fontSize: 11, color: currentTextSecondaryColor),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                              ),
                              child: recipe['image'] != null && recipe['image'].isNotEmpty
                                  ? ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.network(
                                  recipe['image'],
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      Icon(Icons.restaurant, color: primaryColor, size: 24),
                                ),
                              )
                                  : Icon(Icons.restaurant, color: primaryColor, size: 24),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    recipe['title'] ?? 'Không có tiêu đề',
                                    style: TextStyle(
                                        fontSize: 12, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Icon(Icons.access_time, size: 12, color: currentTextSecondaryColor),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${recipe['readyInMinutes'] ?? 'N/A'} phút',
                                        style: TextStyle(fontSize: 11, color: currentTextSecondaryColor),
                                      ),
                                      const SizedBox(width: 12),
                                      Icon(Icons.schedule, size: 12, color: currentTextSecondaryColor),
                                      const SizedBox(width: 4),
                                      Text(
                                        recipe['timeSlot'] == 'morning'
                                            ? 'Sáng'
                                            : recipe['timeSlot'] == 'afternoon'
                                            ? 'Trưa'
                                            : 'Tối',
                                        style: TextStyle(fontSize: 11, color: currentTextSecondaryColor),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              children: [
                                Container(
                                  decoration: BoxDecoration(
                                    color: widget.isDarkMode ? Colors.grey[800] : Colors.blue[50],
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: IconButton(
                                    icon: Icon(Icons.edit, color: primaryColor, size: 16),
                                    onPressed: () => _showEditRecipeDialog(recipe, recipe['favoriteRecipeId']),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  decoration: BoxDecoration(
                                    color: widget.isDarkMode ? Colors.grey[800] : Colors.red[50],
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: IconButton(
                                    icon: Icon(Icons.delete, color: errorColor, size: 16),
                                    onPressed: () => _deleteFavoriteRecipe(recipe['favoriteRecipeId']),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
          ],
        ),
        backgroundColor: errorColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
          ],
        ),
        backgroundColor: successColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: currentBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            SlideTransition(
              position: _headerSlideAnimation,
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, accentColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -40,
                      top: -40,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -15,
                      bottom: -25,
                      child: Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.05),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 16),
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
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          colors: [secondaryColor, Colors.white.withOpacity(0.3)],
                                          radius: 0.8,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.favorite,
                                        color: Colors.white,
                                        size: 16,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Công Thức Yêu Thích',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    '${_favoriteRecipes.length} công thức',
                                    style: TextStyle(
                                      fontSize: 10,
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
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _isLoading
                        ? _buildSkeletonLoader()
                        : _favoriteRecipes.isEmpty
                        ? _buildEmptyState()
                        : FadeTransition(
                      opacity: _fadeAnimation,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            const SizedBox(height: 12),
                            ...List.generate(
                              _favoriteRecipes.length,
                                  (index) => _buildRecipeCard(_favoriteRecipes[index], index),
                            ),
                            const SizedBox(height: 80),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _headerController.dispose();
    super.dispose();
  }
}