import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:loading_animation_widget/loading_animation_widget.dart';
import 'config.dart';

class ThemeColors {
  final bool isDarkMode;
  ThemeColors({required this.isDarkMode});

  Color get primary => isDarkMode ? const Color(0xFF1976D2) : const Color(0xFF2196F3);
  Color get accent => isDarkMode ? const Color(0xFF00BCD4) : const Color(0xFF00ACC1);
  Color get secondary => isDarkMode ? const Color(0xFF757575) : const Color(0xFF9E9E9E);
  Color get error => isDarkMode ? const Color(0xFFD32F2F) : const Color(0xFFF44336);
  Color get warning => isDarkMode ? const Color(0xFFFBC02D) : const Color(0xFFFFC107);
  Color get success => isDarkMode ? const Color(0xFF388E3C) : const Color(0xFF4CAF50);
  Color get background => isDarkMode ? const Color(0xFF121212) : const Color(0xFFFFFFFF);
  Color get surface => isDarkMode ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);
  Color get textPrimary => isDarkMode ? const Color(0xFFFFFFFF) : const Color(0xFF212121);
  Color get textSecondary => isDarkMode ? const Color(0xFFBDBDBD) : const Color(0xFF757575);

  List<Color> get chartColors => [primary, error, success, secondary];
}

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
  final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      printTime: true,
    ),
  );

  late AnimationController _animationController;
  late AnimationController _headerController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;
  late Animation<Offset> _headerSlideAnimation;

  ThemeColors get _themeColors => ThemeColors(isDarkMode: widget.isDarkMode);

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
      begin: const Offset(0, 20),
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
        if (_favoriteRecipes.isEmpty) {
          _showErrorSnackBar('Không có công thức yêu thích nào!');
        }
      } else {
        throw Exception('Không thể tải công thức yêu thích: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi tải công thức yêu thích: $e', stackTrace: stackTrace);
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
        backgroundColor: _themeColors.surface,
        title: Row(
          children: [
            Icon(Icons.delete_outline, color: _themeColors.error, size: 24),
            const SizedBox(width: 8),
            Text(
              'Xác nhận xóa',
              style: TextStyle(color: _themeColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        content: Text(
          'Bạn có chắc chắn muốn xóa công thức này khỏi danh sách yêu thích?',
          style: TextStyle(color: _themeColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: _themeColors.textSecondary)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColors.error,
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
      _logger.e('Lỗi xóa công thức yêu thích: $e', stackTrace: stackTrace);
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
      _logger.e('Lỗi cập nhật công thức yêu thích: $e', stackTrace: stackTrace);
      setState(() {
        _error = 'Lỗi khi cập nhật công thức yêu thích: $e';
        _showErrorSnackBar(_error!);
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }
  Widget _buildModernTextField({
    required String label,
    required String hint,
    required IconData icon,
    required TextEditingController controller,
    int maxLines = 1,
  }) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [_themeColors.surface, _themeColors.surface.withOpacity(0.95)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        style: TextStyle(color: _themeColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: _themeColors.textSecondary, fontWeight: FontWeight.w600, fontSize: 14),
          hintText: hint,
          hintStyle: TextStyle(color: _themeColors.textSecondary.withOpacity(0.6), fontSize: 14),
          prefixIcon: Icon(icon, color: _themeColors.primary, size: 20),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: Colors.transparent,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        ),
      ),
    );
  }
  void _showEditRecipeDialog(Map<String, dynamic> recipe, String favoriteRecipeId) {
    final TextEditingController titleController = TextEditingController(text: recipe['title'] ?? 'Không có tiêu đề');
    final TextEditingController instructionsController = TextEditingController(text: recipe['instructions'] ?? 'Không có hướng dẫn');

    showDialog(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: _themeColors.surface,
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.65,
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_themeColors.primary, _themeColors.accent],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
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
                      _buildModernTextField(
                        label: 'Tiêu đề công thức',
                        hint: 'Nhập tiêu đề công thức',
                        icon: Icons.title,
                        controller: titleController,
                      ),
                      const SizedBox(height: 12),
                      if (recipe['image'] != null && recipe['image'].isNotEmpty)
                        Container(
                          height: MediaQuery.of(context).size.height * 0.15,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.08),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              recipe['image'],
                              fit: BoxFit.cover,
                              loadingBuilder: (context, child, loadingProgress) {
                                if (loadingProgress == null) return child;
                                return Center(
                                  child: LoadingAnimationWidget.threeArchedCircle(
                                    color: _themeColors.primary,
                                    size: 32,
                                  ),
                                );
                              },
                              errorBuilder: (context, error, stackTrace) => Container(
                                decoration: BoxDecoration(
                                  color: _themeColors.background,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Icon(Icons.broken_image, size: 32, color: _themeColors.textSecondary),
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 12),
                      _buildModernTextField(
                        label: 'Hướng dẫn nấu ăn',
                        hint: 'Nhập hướng dẫn nấu ăn',
                        icon: Icons.description,
                        controller: instructionsController,
                        maxLines: 3,
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
                      child: Text('Hủy', style: TextStyle(color: _themeColors.textSecondary)),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [_themeColors.accent, _themeColors.accent.withOpacity(0.7)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(8),
                        boxShadow: [
                          BoxShadow(
                            color: _themeColors.accent.withOpacity(0.2),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
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
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        child: const Text(
                          'Lưu thay đổi',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
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
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: _themeColors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.2 : 0.08),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 48,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: _themeColors.secondary.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          recipe['title'] ?? 'Không có tiêu đề',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: _themeColors.textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: _isLoading
                            ? const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        )
                            : Icon(
                          Icons.favorite,
                          color: _themeColors.error,
                          size: 32,
                        ),
                        onPressed: _isLoading
                            ? null
                            : () => _deleteFavoriteRecipe(recipe['favoriteRecipeId']),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (recipe['image']?.isNotEmpty ?? false)
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.2 : 0.08),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.network(
                          recipe['image'],
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            height: 200,
                            color: _themeColors.background,
                            child: Icon(Icons.broken_image, size: 48, color: _themeColors.textSecondary),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _themeColors.primary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.access_time, color: _themeColors.primary, size: 24),
                        const SizedBox(width: 10),
                        Text(
                          'Thời gian chuẩn bị: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _themeColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (recipe['nutrition']?.isNotEmpty ?? false)
                    _buildNutritionSection(recipe['nutrition']),
                  const SizedBox(height: 20),
                  if (recipe['ingredientsUsed']?.isNotEmpty ?? false)
                    _buildIngredientSection(
                      'Nguyên liệu có sẵn',
                      (recipe['ingredientsUsed'] as List<dynamic>)
                          .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                          .toList(),
                    ),
                  const SizedBox(height: 20),
                  if (recipe['ingredientsMissing']?.isNotEmpty ?? false)
                    _buildIngredientSection(
                      'Nguyên liệu còn thiếu',
                      (recipe['ingredientsMissing'] as List<dynamic>)
                          .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                          .toList(),
                      _themeColors.warning,
                      Icons.shopping_cart,
                    ),
                  const SizedBox(height: 24),
                  Text(
                    'Hướng dẫn',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _themeColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _themeColors.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _themeColors.secondary.withOpacity(0.4)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.05 : 0.02),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Text(
                      recipe['instructions'] ?? 'Không có hướng dẫn',
                      style: TextStyle(
                        fontSize: 15,
                        color: _themeColors.textPrimary,
                        height: 1.6,
                      ),
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

  Widget _buildNutritionSection(List<dynamic> nutrients) {
    final keyNutrients = ['Calories', 'Fat', 'Carbohydrates', 'Protein'];
    final filteredNutrients = nutrients.where((n) => n is Map && keyNutrients.contains(n['name'])).toList();
    final nutrientData = {
      'Calories': filteredNutrients.firstWhere(
            (n) => n['name'] == 'Calories',
        orElse: () => {'amount': 0.0, 'unit': 'kcal'},
      )['amount']?.toDouble() ?? 0.0,
      'Fat': filteredNutrients.firstWhere(
            (n) => n['name'] == 'Fat',
        orElse: () => {'amount': 0.0, 'unit': 'g'},
      )['amount']?.toDouble() ?? 0.0,
      'Carbohydrates': filteredNutrients.firstWhere(
            (n) => n['name'] == 'Carbohydrates',
        orElse: () => {'amount': 0.0, 'unit': 'g'},
      )['amount']?.toDouble() ?? 0.0,
      'Protein': filteredNutrients.firstWhere(
            (n) => n['name'] == 'Protein',
        orElse: () => {'amount': 0.0, 'unit': 'g'},
      )['amount']?.toDouble() ?? 0.0,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Thông tin dinh dưỡng',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: _themeColors.textPrimary,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          height: 200,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _themeColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _themeColors.secondary.withOpacity(0.3)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.1 : 0.03),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: nutrientData.values.every((value) => value == 0.0)
              ? Center(
            child: Text(
              'Không có dữ liệu dinh dưỡng',
              style: TextStyle(color: _themeColors.textSecondary, fontSize: 15),
            ),
          )
              : PieChart(
            PieChartData(
              sections: [
                PieChartSectionData(
                  value: nutrientData['Calories']!,
                  color: _themeColors.chartColors[0],
                  title: 'Calo',
                  titleStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 60,
                ),
                PieChartSectionData(
                  value: nutrientData['Fat']!,
                  color: _themeColors.chartColors[1],
                  title: 'Chất béo',
                  titleStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 60,
                ),
                PieChartSectionData(
                  value: nutrientData['Carbohydrates']!,
                  color: _themeColors.chartColors[2],
                  title: 'Carb',
                  titleStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 60,
                ),
                PieChartSectionData(
                  value: nutrientData['Protein']!,
                  color: _themeColors.chartColors[3],
                  title: 'Protein',
                  titleStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 60,
                ),
              ],
              sectionsSpace: 3,
              centerSpaceRadius: 50,
              borderData: FlBorderData(show: false),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: filteredNutrients
              .map((nutrient) => Chip(
            label: Text(
              nutrient['name'] == 'Calories'
                  ? 'Calo: ${nutrient['amount']?.toStringAsFixed(1) ?? '0.0'} ${nutrient['unit'] ?? ''}'
                  : nutrient['name'] == 'Fat'
                  ? 'Chất béo: ${nutrient['amount']?.toStringAsFixed(1) ?? '0.0'} ${nutrient['unit'] ?? ''}'
                  : nutrient['name'] == 'Carbohydrates'
                  ? 'Carb: ${nutrient['amount']?.toStringAsFixed(1) ?? '0.0'} ${nutrient['unit'] ?? ''}'
                  : 'Protein: ${nutrient['amount']?.toStringAsFixed(1) ?? '0.0'} ${nutrient['unit'] ?? ''}',
              style: TextStyle(color: _themeColors.textPrimary, fontSize: 13),
            ),
            backgroundColor: _themeColors.accent.withOpacity(0.15),
            side: BorderSide(color: _themeColors.accent.withOpacity(0.4)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ))
              .toList(),
        ),
      ],
    );
  }

  Widget _buildIngredientSection(String title, List<String> ingredients, [Color? color, IconData? icon]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon ?? Icons.check_circle, color: color ?? _themeColors.primary, size: 20),
            const SizedBox(width: 10),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _themeColors.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (ingredients.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _themeColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _themeColors.secondary.withOpacity(0.3)),
            ),
            child: Text(
              title.contains('có sẵn') ? 'Không có nguyên liệu sẵn có' : 'Không có nguyên liệu còn thiếu',
              style: TextStyle(color: _themeColors.textSecondary, fontSize: 15),
            ),
          )
        else
          ...ingredients.map((ingredient) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: (color ?? _themeColors.primary).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: (color ?? _themeColors.primary).withOpacity(0.3)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.05 : 0.02),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Icon(Icons.circle, color: color ?? _themeColors.primary, size: 12),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ingredient,
                    style: TextStyle(color: _themeColors.textPrimary, fontSize: 15),
                  ),
                ),
              ],
            ),
          )),
      ],
    );
  }

  Widget _buildRecipeTile(Map<String, dynamic> recipe) {
    if (recipe.isEmpty || recipe['title'] == null || recipe['favoriteRecipeId'] == null) {
      _logger.w('Invalid recipe, skipping: $recipe');
      return const SizedBox.shrink();
    }
    return Dismissible(
      key: Key(recipe['favoriteRecipeId']),
      background: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _themeColors.success,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Row(
          children: [
            Icon(Icons.edit, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Text(
              'Chỉnh sửa',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _themeColors.error,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              'Xóa',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.delete, color: Colors.white, size: 28),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.endToStart) {
          // Delete action
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              backgroundColor: _themeColors.surface,
              title: Row(
                children: [
                  Icon(Icons.delete_outline, color: _themeColors.error, size: 24),
                  const SizedBox(width: 8),
                  Text(
                    'Xác nhận xóa',
                    style: TextStyle(color: _themeColors.textPrimary, fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ],
              ),
              content: Text(
                'Bạn có chắc chắn muốn xóa công thức này khỏi danh sách yêu thích?',
                style: TextStyle(color: _themeColors.textSecondary, fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Hủy', style: TextStyle(color: _themeColors.textSecondary)),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _themeColors.error,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Xóa', style: TextStyle(color: Colors.white)),
                ),
              ],
            ),
          );
          return confirmed ?? false;
        } else if (direction == DismissDirection.startToEnd) {
          // Edit action
          _showEditRecipeDialog(recipe, recipe['favoriteRecipeId']);
          return false; // Prevent dismissing the tile on edit
        }
        return false;
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          _deleteFavoriteRecipe(recipe['favoriteRecipeId']);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _themeColors.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.2 : 0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _showRecipeDetails(recipe),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: _themeColors.background,
                    ),
                    child: recipe['image']?.isNotEmpty ?? false
                        ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        recipe['image'],
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Icon(
                          Icons.restaurant,
                          color: _themeColors.primary,
                          size: 32,
                        ),
                      ),
                    )
                        : Icon(Icons.restaurant, color: _themeColors.primary, size: 32),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          recipe['title'] ?? 'Không có tiêu đề',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: _themeColors.textPrimary,
                            fontSize: 16,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Thời gian: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
                          style: TextStyle(
                            color: _themeColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.favorite,
                      color: _themeColors.error,
                      size: 28,
                    ),
                    onPressed: _isLoading
                        ? null
                        : () => _deleteFavoriteRecipe(recipe['favoriteRecipeId']),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
  Widget _buildShimmerLoading() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 6,
      itemBuilder: (context, _) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: _themeColors.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.1 : 0.03),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _themeColors.background,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 18,
                      width: double.infinity,
                      color: _themeColors.background,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      height: 14,
                      width: 150,
                      color: _themeColors.background,
                    ),
                  ],
                ),
              ),
              Container(
                width: 28,
                height: 28,
                color: _themeColors.background,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: _themeColors.surface,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.2 : 0.08),
              blurRadius: 16,
              offset: const Offset(0, 6),
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
                  colors: [
                    _themeColors.primary.withOpacity(0.2),
                    _themeColors.primary.withOpacity(0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                Icons.favorite_border,
                size: 64,
                color: _themeColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Chưa có công thức yêu thích',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _themeColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Thêm công thức yêu thích từ màn hình gợi ý để lưu lại và xem bất cứ lúc nào!',
              style: TextStyle(
                fontSize: 16,
                color: _themeColors.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_themeColors.primary, _themeColors.accent],
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: _themeColors.primary.withOpacity(0.4),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.explore, color: Colors.white, size: 24),
                label: const Text(
                  'Khám phá công thức',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
          ],
        ),
        backgroundColor: _themeColors.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
          ],
        ),
        backgroundColor: _themeColors.success,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _themeColors.background,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: SlideTransition(
                position: _headerSlideAnimation,
                child: Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [_themeColors.primary, _themeColors.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: _themeColors.primary.withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        top: -40,
                        right: -40,
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: -40,
                        right: 8,
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.08),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back_ios,
                                color: Colors.white,
                                size: 24,
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                              padding: EdgeInsets.zero,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        Colors.white.withOpacity(0.2),
                                        Colors.white.withOpacity(0.05),
                                      ],
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.favorite,
                                    size: 24,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Công thức yêu thích',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _isLoading
                  ? _buildShimmerLoading()
                  : _favoriteRecipes.isEmpty
                  ? _buildEmptyState()
                  : FadeTransition(
                opacity: _fadeAnimation,
                child: SlideTransition(
                  position: _slideAnimation,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tìm thấy ${_favoriteRecipes.length} công thức yêu thích',
                          style: TextStyle(
                            fontSize: 14,
                            color: _themeColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ..._favoriteRecipes.map((recipe) => _buildRecipeTile(recipe)),
                        const SizedBox(height: 60),
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

  @override
  void dispose() {
    _animationController.dispose();
    _headerController.dispose();
    super.dispose();
  }
}