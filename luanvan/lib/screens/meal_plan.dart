import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:shimmer/shimmer.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'config.dart';

class ThemeColors {
  final bool isDarkMode;

  ThemeColors({required this.isDarkMode});

  Color get primaryColor => isDarkMode ? Colors.blue[700]! : Colors.blue[500]!;
  Color get accentColor => isDarkMode ? Colors.cyan[600]! : Colors.cyan[400]!;
  Color get secondaryColor => isDarkMode ? Colors.grey[600]! : Colors.grey[400]!;
  Color get errorColor => isDarkMode ? Colors.red[400]! : Colors.red[600]!;
  Color get warningColor => isDarkMode ? Colors.amber[400]! : Colors.amber[600]!;
  Color get successColor => isDarkMode ? Colors.green[400]! : Colors.green[600]!;
  Color get currentBackgroundColor => isDarkMode ? Colors.grey[900]! : Colors.white;
  Color get currentSurfaceColor => isDarkMode ? Colors.grey[800]! : Colors.grey[50]!;
  Color get currentTextPrimaryColor => isDarkMode ? Colors.white : Colors.grey[900]!;
  Color get currentTextSecondaryColor => isDarkMode ? Colors.grey[400]! : Colors.grey[600]!;
}

class MealPlanScreen extends StatefulWidget {
  final String userId;
  final bool isDarkMode;

  const MealPlanScreen({
    super.key,
    required this.userId,
    required this.isDarkMode,
  });

  @override
  _MealPlanScreenState createState() => _MealPlanScreenState();
}

class _MealPlanScreenState extends State<MealPlanScreen> with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _headerAnimationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _headerSlideAnimation;

  Map<String, Map<String, List<Map<String, dynamic>>>> _mealPlan = {};
  Map<String, List<String>> _seenRecipeIds = {'week': []};
  bool _isLoading = false;
  String? _errorMessage;
  String? _selectedDiet;
  int _targetCalories = 2000;
  bool _useFridgeIngredients = false;
  String _selectedTimeFrame = 'week';
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();
  Set<String> _favoriteRecipeIds = {};
  Set<String> _calendarDaysWithRecipes = {};

  final String _ngrokUrl = Config.getNgrokUrl();
  final Logger _logger = Logger();
  final http.Client _httpClient = http.Client();

  final List<String> _diets = ['Vegetarian', 'Vegan', 'Gluten Free', 'Ketogenic', 'Pescatarian'];
  final List<String> _timeFrames = ['day', 'three_days', 'week'];
  final Map<String, String> _timeFrameTranslations = {
    'day': '1 Ngày',
    'three_days': '3 Ngày',
    'week': 'Tuần',
  };

  ThemeColors get _themeColors => ThemeColors(isDarkMode: widget.isDarkMode);

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializeLocale();
    _initializeData();
  }

  Future<void> _initializeLocale() async {
    await initializeDateFormatting('vi_VN', null);
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
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _headerAnimationController, curve: Curves.easeOut),
    );
    _headerAnimationController.forward();
    _animationController.forward();
  }

  Future<void> _initializeData() async {
    try {
      await _loadFavoriteRecipes();
    } catch (e, stackTrace) {
      _logger.e('Lỗi khởi tạo: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể khởi tạo dữ liệu. Vui lòng thử lại.', _themeColors.errorColor);
    }
  }

  Future<void> _loadFavoriteRecipes() async {
    setState(() => _isLoading = true);
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final favorites = List<Map<String, dynamic>>.from(data['favoriteRecipes'] ?? []);
        setState(() {
          _favoriteRecipeIds = favorites.map((r) => r['recipeId'].toString()).toSet();
        });
        _logger.i('Đã tải ${favorites.length} công thức yêu thích');
      } else {
        throw Exception('Không thể tải công thức yêu thích: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải công thức yêu thích: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể tải công thức yêu thích.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<List<Map<String, dynamic>>> _fetchFridgeIngredients() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/get_user_ingredients?userId=${widget.userId}'),
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<Map<String, dynamic>>.from(data['ingredients'] ?? []);
      } else {
        throw Exception('Không thể lấy nguyên liệu từ Firestore: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi lấy nguyên liệu từ Firestore: $e', stackTrace: stackTrace);
      return [];
    }
  }

  Future<void> _generateWeeklyMealPlan() async {
    if (_isLoading) {
      _logger.i('Đang tạo kế hoạch bữa ăn, bỏ qua yêu cầu mới');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      List<Map<String, dynamic>> ingredients = [];
      if (_useFridgeIngredients) {
        ingredients = await _fetchFridgeIngredients();
      }

      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/generate_weekly_meal_plan'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': widget.userId,
          'diet': _selectedDiet ?? '',
          'maxCalories': _targetCalories,
          'timeFrame': _selectedTimeFrame,
          'useFridgeIngredients': _useFridgeIngredients,
          'ingredients': ingredients,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final mealPlanData = data['mealPlan'] as List<dynamic>? ?? [];
        _logger.i('Raw mealPlanData: $mealPlanData');
        final processedWeek = <String, List<Map<String, dynamic>>>{};

        for (var day in mealPlanData) {
          final date = day['day'] as String;
          final meals = day['meals'] as Map<String, dynamic>;
          // THAY ĐỔI: Sử dụng trực tiếp date từ backend, đảm bảo định dạng YYYY-MM-DD
          final dateKey = date;
          _logger.i('Processing day: $dateKey, meals: $meals');
          processedWeek.putIfAbsent(dateKey, () => []);
          for (var timeSlot in ['morning', 'afternoon', 'evening']) {
            final recipes = meals[timeSlot] as List<dynamic>? ?? [];
            _logger.i('Recipes for $timeSlot on $dateKey: ${recipes.length}');
            for (var recipe in recipes) {
              // THAY ĐỔI: Xử lý trường hợp id là null
              final recipeId = recipe['id']?.toString() ?? 'fallback_${DateTime.now().millisecondsSinceEpoch}';
              processedWeek[dateKey]!.add({
                'id': recipeId,
                'title': recipe['title'] ?? 'Không có tiêu đề',
                'image': recipe['image'] ?? '',
                'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
                'ingredientsUsed': recipe['ingredientsUsed']?.map((e) => ({
                  'name': e['name']?.toString() ?? '',
                  'amount': e['amount'] ?? 0,
                  'unit': e['unit']?.toString() ?? '',
                })).toList() ?? [],
                'ingredientsMissing': recipe['ingredientsMissing']?.map((e) => ({
                  'name': e['name']?.toString() ?? '',
                  'amount': e['amount'] ?? 0,
                  'unit': e['unit']?.toString() ?? '',
                })).toList() ?? [],
                'instructions': recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
                'nutrition': recipe['nutrition'] ?? [],
                'isFavorite': _favoriteRecipeIds.contains(recipeId),
                'timeSlot': timeSlot,
                'diets': recipe['diets'] ?? [],
                'relevanceScore': recipe['relevanceScore'] ?? 0.0,
              });
            }
          }
        }

        _logger.i('Processed week: $processedWeek');
        _logger.i('Processed week keys: ${processedWeek.keys}');
        _logger.i('Total recipes: ${processedWeek.values.fold<int>(0, (sum, e) => sum + e.length)}');

        setState(() {
          _mealPlan = {'week': processedWeek};
          _seenRecipeIds['week'] = processedWeek.values.expand((e) => e).map((r) => r['id'].toString()).toList();
          if (processedWeek.isNotEmpty) {
            _selectedDay = DateTime.parse(processedWeek.keys.first);
            _focusedDay = _selectedDay;
            _logger.i('Set selectedDay to: $_selectedDay');
          }
          _logger.i('Updated mealPlan: $_mealPlan');
        });
        _showSnackBar(
          'Đã tạo kế hoạch ${_timeFrameTranslations[_selectedTimeFrame]} với ${processedWeek.values.fold<int>(0, (sum, e) => sum + e.length)} công thức! Nhấn "Thêm ngày vào lịch" để lưu.',
          _themeColors.successColor,
        );
      } else {
        throw Exception('Không thể tải kế hoạch bữa ăn: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tạo kế hoạch bữa ăn: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Không thể tạo kế hoạch bữa ăn: $e';
      });
      _showSnackBar('Không thể tạo kế hoạch bữa ăn.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addDayToCalendar(DateTime day) async {
    setState(() => _isLoading = true);
    try {
      final dateKey = day.toIso8601String().split('T')[0];
      final meals = _mealPlan['week']?[dateKey] ?? [];
      if (meals.isEmpty) {
        _showSnackBar('Không có công thức nào cho ngày này để thêm vào lịch.', _themeColors.warningColor);
        return;
      }

      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/add_to_calendar'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': widget.userId,
          'date': dateKey,
          'meals': meals,
        }),
      );

      if (response.statusCode == 200) {
        setState(() {
          _calendarDaysWithRecipes.add(dateKey);
        });
        _showSnackBar('Đã thêm các công thức vào lịch cho ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)}!', _themeColors.successColor);
      } else {
        throw Exception('Không thể thêm vào lịch: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi thêm vào lịch: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể thêm vào lịch.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _removeDayFromCalendar(DateTime day) async {
    setState(() => _isLoading = true);
    try {
      final dateKey = day.toIso8601String().split('T')[0];
      if (!_calendarDaysWithRecipes.contains(dateKey)) {
        _showSnackBar('Ngày này chưa được thêm vào lịch.', _themeColors.warningColor);
        return;
      }

      final response = await _httpClient.delete(
        Uri.parse('$_ngrokUrl/remove_from_calendar?userId=${widget.userId}&date=$dateKey'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _calendarDaysWithRecipes.remove(dateKey);
        });
        _showSnackBar('Đã xóa ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)} khỏi lịch!', _themeColors.successColor);
      } else {
        throw Exception('Không thể xóa khỏi lịch: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi xóa khỏi lịch: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể xóa khỏi lịch.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _showRecipesForDay(DateTime day) async {
    final dateKey = day.toIso8601String().split('T')[0];
    _logger.i('Showing recipes for day: $dateKey, in calendar: ${_calendarDaysWithRecipes.contains(dateKey)}');
    if (!_calendarDaysWithRecipes.contains(dateKey)) {
      _showSnackBar('Ngày này chưa có công thức nào trong lịch.', _themeColors.warningColor);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/get_calendar_meals?userId=${widget.userId}&date=$dateKey'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final meals = List<Map<String, dynamic>>.from(data['meals'] ?? []);
        _logger.i('Meals from calendar for $dateKey: $meals');
        if (meals.isEmpty) {
          _showSnackBar('Không có công thức nào cho ngày này trong lịch.', _themeColors.warningColor);
        } else {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (context) => DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.9,
              expand: true,
              builder: (context, scrollController) => Container(
                decoration: BoxDecoration(
                  color: _themeColors.currentSurfaceColor,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Công thức cho ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)}',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _themeColors.currentTextPrimaryColor,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: meals.length,
                        itemBuilder: (context, index) => _buildRecipeTile(meals[index]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      } else {
        throw Exception('Không thể tải công thức từ lịch: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải công thức từ lịch: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể tải công thức từ lịch.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<Map<String, dynamic>> _fetchMealDetails(String id) async {
    final response = await _httpClient.get(
      Uri.parse('$_ngrokUrl/recipes/$id/information'),
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body) as Map<String, dynamic>;
      _logger.i('Fetched meal details for id $id: $data');
      return {
        'id': data['id'],
        'title': data['title'] ?? 'Không xác định',
        'image': data['image'] as String?,
        'readyInMinutes': data['readyInMinutes'] as int?,
        'ingredientsUsed': data['ingredientsUsed'] as List<dynamic>? ?? [],
        'ingredientsMissing': data['ingredientsMissing'] as List<dynamic>? ?? [],
        'instructions': data['instructions'] as String?,
        'nutrition': data['nutrition'] as List<dynamic>?,
        'diets': data['diets'] as List<dynamic>?,
        'relevanceScore': data['relevanceScore'] as double?,
      };
    }
    throw Exception('Không thể tải chi tiết công thức: $id');
  }

  Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
    setState(() => _isLoading = true);
    try {
      if (isFavorite) {
        final response = await _httpClient.delete(
          Uri.parse('$_ngrokUrl/delete_favorite_recipe/$recipeId?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          setState(() {
            _favoriteRecipeIds.remove(recipeId);
            _updateMealPlanFavoriteStatus(recipeId, false);
          });
          _showSnackBar('Đã xóa khỏi yêu thích!', _themeColors.successColor);
        } else {
          throw Exception('Không thể xóa công thức yêu thích: ${response.statusCode}');
        }
      } else {
        final meals = _mealPlan['week'];
        if (meals == null) {
          throw Exception('Kế hoạch bữa ăn chưa được khởi tạo');
        }

        final recipe = meals.values
            .expand((e) => e)
            .firstWhere((r) => r['id'].toString() == recipeId, orElse: () => {});
        if (recipe.isEmpty) {
          throw Exception('Không tìm thấy công thức');
        }

        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/add_favorite_recipe'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'userId': widget.userId,
            'recipeId': recipeId,
            'title': recipe['title']?.toString() ?? 'Không có tiêu đề',
            'imageUrl': recipe['image']?.toString() ?? '',
            'instructions': recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
            'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
            'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
            'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
            'timeSlot': recipe['timeSlot']?.toString() ?? 'other',
            'nutrition': recipe['nutrition'] ?? [],
            'diets': recipe['diets'] ?? [],
            'relevanceScore': recipe['relevanceScore'] ?? 0.0,
          }),
        );

        if (response.statusCode == 200) {
          setState(() {
            _favoriteRecipeIds.add(recipeId);
            _updateMealPlanFavoriteStatus(recipeId, true);
          });
          _showSnackBar('Đã thêm vào yêu thích!', _themeColors.successColor);
        } else {
          throw Exception('Không thể thêm công thức yêu thích: ${response.statusCode}');
        }
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi cập nhật trạng thái yêu thích: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể cập nhật trạng thái yêu thích.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _updateMealPlanFavoriteStatus(String recipeId, bool isFavorite) {
    final meals = _mealPlan['week'];
    if (meals != null) {
      for (var dayMeals in meals.values) {
        final recipeIndex = dayMeals.indexWhere((r) => r['id'].toString() == recipeId);
        if (recipeIndex != -1) {
          dayMeals[recipeIndex]['isFavorite'] = isFavorite;
        }
      }
    }
  }

  Future<void> _addToShoppingList(Map<String, dynamic> recipe) async {
    setState(() => _isLoading = true);
    try {
      final missingIngredients = (recipe['ingredientsMissing'] as List<dynamic>?)?.map((e) => ({
        'name': e['name']?.toString() ?? '',
        'amount': e['amount'] ?? 0,
        'unit': e['unit']?.toString() ?? '',
      })).toList() ?? [];
      if (missingIngredients.isEmpty) {
        _showSnackBar('Không có nguyên liệu cần thêm.', _themeColors.successColor);
        return;
      }

      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/place_order'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'userId': widget.userId,
          'items': missingIngredients,
        }),
      );

      if (response.statusCode == 200) {
        _showSnackBar('Đã thêm ${missingIngredients.length} nguyên liệu vào danh sách mua sắm!', _themeColors.successColor);
      } else {
        throw Exception('Không thể thêm vào danh sách mua sắm: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi thêm vào danh sách mua sắm: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể thêm vào danh sách mua sắm.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String message, Color backgroundColor) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              backgroundColor == _themeColors.errorColor ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontSize: 14))),
          ],
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.all(12),
      ),
    );
  }

  void _showRecipeDetails(Map<String, dynamic> recipe) {
    _logger.i('Showing recipe details: $recipe');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: true,
        builder: (context, scrollController) => Container(
          decoration: BoxDecoration(
            color: _themeColors.currentSurfaceColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: DefaultTabController(
            length: 4,
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                TabBar(
                  labelColor: _themeColors.primaryColor,
                  unselectedLabelColor: _themeColors.secondaryColor,
                  indicatorColor: _themeColors.primaryColor,
                  tabs: const [
                    Tab(text: 'Tổng quan'),
                    Tab(text: 'Nguyên liệu'),
                    Tab(text: 'Hướng dẫn'),
                    Tab(text: 'Lịch'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    recipe['title']?.toString() ?? 'Không có tiêu đề',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: _themeColors.currentTextPrimaryColor,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  icon: _isLoading
                                      ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                      : Icon(
                                    recipe['isFavorite'] == true ? Icons.favorite : Icons.favorite_border,
                                    color: recipe['isFavorite'] == true
                                        ? _themeColors.errorColor
                                        : _themeColors.currentTextSecondaryColor,
                                    size: 24,
                                  ),
                                  onPressed: _isLoading
                                      ? null
                                      : () {
                                    setState(() {
                                      recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
                                    });
                                    _toggleFavorite(recipe['id'].toString(), !(recipe['isFavorite'] ?? false));
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            if (recipe['image']?.toString().isNotEmpty == true)
                              Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 5,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: Image.network(
                                    recipe['image'].toString(),
                                    height: 180,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      height: 180,
                                      color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
                                      child: Icon(
                                        Icons.broken_image,
                                        size: 40,
                                        color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[600],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _themeColors.primaryColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.access_time, color: _themeColors.primaryColor, size: 20),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Thời gian chuẩn bị: ${recipe['readyInMinutes']?.toString() ?? 'N/A'} phút',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: _themeColors.primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                            if ((recipe['nutrition'] as List<dynamic>?)?.isNotEmpty == true)
                              _buildNutritionSection(recipe['nutrition'] as List<dynamic>),
                          ],
                        ),
                      ),
                      SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            if ((recipe['ingredientsUsed'] as List<dynamic>?)?.isNotEmpty == true)
                              _buildIngredientsSection(
                                'Nguyên liệu có sẵn',
                                (recipe['ingredientsUsed'] as List<dynamic>)
                                    .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                                    .toList(),
                              ),
                            const SizedBox(height: 16),
                            if ((recipe['ingredientsMissing'] as List<dynamic>?)?.isNotEmpty == true)
                              _buildIngredientsSection(
                                'Nguyên liệu còn thiếu',
                                (recipe['ingredientsMissing'] as List<dynamic>)
                                    .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                                    .toList(),
                                _themeColors.warningColor,
                                Icons.shopping_cart,
                              ),
                            const SizedBox(height: 16),
                            if ((recipe['ingredientsMissing'] as List<dynamic>?)?.isNotEmpty == true)
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(colors: [_themeColors.accentColor, _themeColors.primaryColor]),
                                  borderRadius: BorderRadius.circular(10),
                                  boxShadow: [
                                    BoxShadow(
                                      color: _themeColors.accentColor.withOpacity(0.3),
                                      blurRadius: 6,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : () => _addToShoppingList(recipe),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    shadowColor: Colors.transparent,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.add_shopping_cart, color: Colors.white, size: 20),
                                      const SizedBox(width: 8),
                                      Text(
                                        _isLoading ? 'Đang thêm...' : 'Thêm vào danh sách mua sắm',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(
                              'Hướng dẫn',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: _themeColors.currentTextPrimaryColor,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
                                ),
                              ),
                              child: Text(
                                recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: _themeColors.currentTextPrimaryColor,
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Quản lý lịch',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: _themeColors.currentTextPrimaryColor,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [_themeColors.primaryColor, _themeColors.accentColor]),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : () => _addDayToCalendar(_selectedDay),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: Text(
                                  _isLoading ? 'Đang thêm...' : 'Thêm ngày vào lịch',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [_themeColors.errorColor, _themeColors.warningColor]),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : () => _removeDayFromCalendar(_selectedDay),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: Text(
                                  _isLoading ? 'Đang xóa...' : 'Xóa ngày khỏi lịch',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNutritionSection(List<dynamic> nutrition) {
    final keyNutrients = ['Calories', 'Fat', 'Carbohydrates', 'Protein'];
    final filteredNutrients = nutrition.where((n) => keyNutrients.contains(n['name'])).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Thông tin dinh dưỡng',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: _themeColors.currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: filteredNutrients.map((nutrient) => Chip(
            label: Text(
              '${nutrient['name']}: ${nutrient['amount']?.toStringAsFixed(1) ?? '0.0'} ${nutrient['unit'] ?? ''}',
              style: TextStyle(
                color: _themeColors.currentTextPrimaryColor,
                fontSize: 12,
              ),
            ),
            backgroundColor: _themeColors.accentColor.withOpacity(0.1),
            side: BorderSide(color: _themeColors.accentColor.withOpacity(0.3)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildIngredientsSection(String title, List<String> items, [Color? color, IconData? icon]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon ?? Icons.check_circle,
              color: color ?? _themeColors.primaryColor,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _themeColors.currentTextPrimaryColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              title.contains('Có sẵn') ? 'Không có nguyên liệu' : 'Không thiếu nguyên liệu',
              style: TextStyle(
                color: _themeColors.currentTextSecondaryColor,
                fontSize: 14,
              ),
            ),
          )
        else
          ...items.map((item) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (color ?? _themeColors.primaryColor).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: (color ?? _themeColors.primaryColor).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  color: color ?? _themeColors.primaryColor,
                  size: 10,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item,
                    style: TextStyle(
                      color: _themeColors.currentTextPrimaryColor,
                      fontSize: 14,
                    ),
                  ),
                ),
              ],
            ),
          )),
      ],
    );
  }

  Future<void> _resetAllMeals() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _seenRecipeIds = {'week': []};
      _mealPlan = {};
      _calendarDaysWithRecipes = {};
    });

    try {
      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/reset_meal_plan_cache'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'userId': widget.userId}),
      );

      if (response.statusCode == 200) {
        _showSnackBar('Đã làm mới kế hoạch bữa ăn!', _themeColors.successColor);
      } else {
        throw Exception('Không thể đặt lại bộ nhớ cache kế hoạch bữa ăn: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi đặt lại kế hoạch bữa ăn: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Không thể đặt lại kế hoạch bữa ăn: $e';
      });
      _showSnackBar('Không thể đặt lại kế hoạch bữa ăn.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // THAY ĐỔI: Thêm hàm mới để reset và tạo lại kế hoạch
  Future<void> _refreshAndGenerateMealPlan() async {
    await _resetAllMeals();
    await _generateWeeklyMealPlan();
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: widget.isDarkMode ? Colors.grey[900]! : Colors.grey[200]!,
      highlightColor: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[100]!,
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        itemBuilder: (context, _) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _themeColors.currentSurfaceColor,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.all(12),
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.grey[300]!,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            title: Container(
              height: 16,
              width: double.infinity,
              color: Colors.grey[300]!,
            ),
            subtitle: Container(
              height: 12,
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              color: Colors.grey[300]!,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecipeTile(Map<String, dynamic> recipe) {
    // THAY ĐỔI: Nới lỏng điều kiện, chỉ yêu cầu title không null
    if (recipe.isEmpty || recipe['title'] == null) {
      _logger.e('Dữ liệu công thức không hợp lệ: $recipe');
      return const SizedBox.shrink();
    }
    _logger.i('Building recipe tile: ${recipe['title']}, id: ${recipe['id']}, timeSlot: ${recipe['timeSlot']}');
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: _themeColors.currentSurfaceColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: widget.isDarkMode ? Colors.grey[900]! : Colors.grey[200]!,
          ),
          child: recipe['image']?.toString().isNotEmpty == true
              ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              recipe['image'].toString(),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(
                Icons.restaurant,
                color: _themeColors.primaryColor,
                size: 24,
              ),
            ),
          )
              : Icon(
            Icons.restaurant,
            color: _themeColors.primaryColor,
            size: 24,
          ),
        ),
        title: Text(
          recipe['title'].toString(),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _themeColors.currentTextPrimaryColor,
            fontSize: 14,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Thời gian: ${recipe['readyInMinutes']?.toString() ?? 'N/A'} phút | ${{
            'morning': 'Sáng',
            'afternoon': 'Trưa',
            'evening': 'Tối',
          }[recipe['timeSlot']] ?? 'Khác'}',
          style: TextStyle(
            color: _themeColors.secondaryColor,
            fontSize: 12,
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            recipe['isFavorite'] == true ? Icons.favorite : Icons.favorite_border,
            color: recipe['isFavorite'] == true ? _themeColors.errorColor : _themeColors.secondaryColor,
            size: 20,
          ),
          onPressed: _isLoading
              ? null
              : () {
            setState(() {
              recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
            });
            _toggleFavorite(recipe['id'].toString(), !(recipe['isFavorite'] ?? false));
          },
        ),
        onTap: () => _showRecipeDetails(recipe),
      ),
    );
  }

  Widget _buildOptionsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _themeColors.currentSurfaceColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tùy chọn kế hoạch bữa ăn',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: _themeColors.currentTextPrimaryColor,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedDiet,
            hint: Text(
              'Chọn chế độ ăn',
              style: TextStyle(color: _themeColors.secondaryColor),
            ),
            items: _diets
                .map((diet) => DropdownMenuItem(
              value: diet,
              child: Text(diet, style: TextStyle(color: _themeColors.currentTextPrimaryColor)),
            ))
                .toList(),
            onChanged: (value) {
              setState(() {
                _selectedDiet = value;
              });
            },
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _themeColors.secondaryColor),
              ),
              filled: true,
              fillColor: _themeColors.currentSurfaceColor,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Lượng calo mục tiêu',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _themeColors.secondaryColor),
              ),
              filled: true,
              fillColor: _themeColors.currentSurfaceColor,
            ),
            onChanged: (value) {
              setState(() {
                _targetCalories = int.tryParse(value) ?? 2000;
              });
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedTimeFrame,
            hint: Text(
              'Chọn khoảng thời gian',
              style: TextStyle(color: _themeColors.secondaryColor),
            ),
            items: _timeFrames
                .map((frame) => DropdownMenuItem(
              value: frame,
              child: Text(
                _timeFrameTranslations[frame]!,
                style: TextStyle(color: _themeColors.currentTextPrimaryColor),
              ),
            ))
                .toList(),
            onChanged: (value) {
              setState(() {
                _selectedTimeFrame = value ?? 'week';
              });
            },
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: _themeColors.secondaryColor),
              ),
              filled: true,
              fillColor: _themeColors.currentSurfaceColor,
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            title: Text(
              'Sử dụng nguyên liệu trong tủ lạnh',
              style: TextStyle(color: _themeColors.currentTextPrimaryColor),
            ),
            value: _useFridgeIngredients,
            onChanged: (value) {
              setState(() {
                _useFridgeIngredients = value;
              });
            },
            activeColor: _themeColors.primaryColor,
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [_themeColors.primaryColor, _themeColors.accentColor]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ElevatedButton(
              onPressed: _isLoading ? null : _generateWeeklyMealPlan,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _isLoading ? 'Đang tạo...' : 'Tạo kế hoạch bữa ăn',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // THAY ĐỔI: Thêm nút để reset và tạo lại kế hoạch
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [_themeColors.primaryColor, _themeColors.accentColor]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ElevatedButton(
              onPressed: _isLoading ? null : _refreshAndGenerateMealPlan,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _isLoading ? 'Đang làm mới...' : 'Làm mới và tạo kế hoạch',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [_themeColors.primaryColor, _themeColors.accentColor]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ElevatedButton(
              onPressed: _isLoading ? null : () => _addDayToCalendar(_selectedDay),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _isLoading ? 'Đang thêm...' : 'Thêm ngày vào lịch',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dateKey = _selectedDay.toIso8601String().split('T')[0];
    _logger.i('MealPlan in build: $_mealPlan');
    _logger.i('Fetching meals for dateKey: $dateKey');
    final mealsForSelectedDay = _mealPlan['week']?[dateKey] ?? [];
    _logger.i('Meals for $dateKey: ${mealsForSelectedDay.length} recipes, meals: $mealsForSelectedDay');
    final mealsByTimeSlot = {
      'morning': mealsForSelectedDay.where((m) => m['timeSlot'] == 'morning').toList(),
      'afternoon': mealsForSelectedDay.where((m) => m['timeSlot'] == 'afternoon').toList(),
      'evening': mealsForSelectedDay.where((m) => m['timeSlot'] == 'evening').toList(),
    };
    _logger.i('Time slots distribution: morning=${mealsByTimeSlot['morning']!.length}, afternoon=${mealsByTimeSlot['afternoon']!.length}, evening=${mealsByTimeSlot['evening']!.length}');
    _logger.i('Morning meals: ${mealsByTimeSlot['morning']}');
    _logger.i('Afternoon meals: ${mealsByTimeSlot['afternoon']}');
    _logger.i('Evening meals: ${mealsByTimeSlot['evening']}');

    return Scaffold(
      backgroundColor: _themeColors.currentBackgroundColor,
      body: SafeArea(
        child: Column(
          children: [
            SlideTransition(
              position: _headerSlideAnimation,
              child: Container(
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [_themeColors.primaryColor, _themeColors.accentColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: _themeColors.primaryColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Kế hoạch bữa ăn',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? _buildShimmerLoading()
                  : CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onDoubleTap: () => _showRecipesForDay(_selectedDay),
                              child: TableCalendar(
                                firstDay: DateTime.utc(2020, 1, 1),
                                lastDay: DateTime.utc(2030, 12, 31),
                                focusedDay: _focusedDay,
                                selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                                onDaySelected: (selectedDay, focusedDay) {
                                  setState(() {
                                    _selectedDay = selectedDay;
                                    _focusedDay = focusedDay;
                                    _logger.i('Selected new day: $selectedDay, dateKey: ${selectedDay.toIso8601String().split('T')[0]}');
                                  });
                                },
                                calendarStyle: CalendarStyle(
                                  selectedDecoration: BoxDecoration(
                                    color: _themeColors.primaryColor,
                                    shape: BoxShape.circle,
                                  ),
                                  todayDecoration: BoxDecoration(
                                    color: _themeColors.accentColor.withOpacity(0.5),
                                    shape: BoxShape.circle,
                                  ),
                                  markerDecoration: BoxDecoration(
                                    color: _themeColors.errorColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                calendarBuilders: CalendarBuilders(
                                  markerBuilder: (context, date, events) {
                                    final dateKey = date.toIso8601String().split('T')[0];
                                    if (_calendarDaysWithRecipes.contains(dateKey)) {
                                      return Positioned(
                                        right: 1,
                                        bottom: 1,
                                        child: Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: _themeColors.errorColor,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                      );
                                    }
                                    return null;
                                  },
                                ),
                                headerStyle: HeaderStyle(
                                  formatButtonVisible: false,
                                  titleCentered: true,
                                  titleTextStyle: TextStyle(
                                    color: _themeColors.currentTextPrimaryColor,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildOptionsCard(),
                            const SizedBox(height: 16),
                            if (_errorMessage != null)
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: _themeColors.errorColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(color: _themeColors.errorColor),
                                ),
                              ),
                            const SizedBox(height: 16),
                            // THAY ĐỔI: Thêm kiểm tra nếu _mealPlan['week'] rỗng
                            if (_mealPlan['week']?.isEmpty ?? true)
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: _themeColors.currentSurfaceColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Chưa có kế hoạch bữa ăn. Vui lòng tạo mới.',
                                  style: TextStyle(
                                    color: _themeColors.currentTextSecondaryColor,
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            else if (mealsForSelectedDay.isNotEmpty)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Bữa ăn cho ${DateFormat('d MMMM, yyyy', 'vi_VN').format(_selectedDay)}',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: _themeColors.currentTextPrimaryColor,
                                        ),
                                      ),
                                      if (_calendarDaysWithRecipes.contains(_selectedDay.toIso8601String().split('T')[0]))
                                        IconButton(
                                          icon: Icon(
                                            Icons.delete,
                                            color: _themeColors.errorColor,
                                            size: 20,
                                          ),
                                          onPressed: _isLoading ? null : () => _removeDayFromCalendar(_selectedDay),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  ...['morning', 'afternoon', 'evening'].map((slot) {
                                    final meals = mealsByTimeSlot[slot]!;
                                    final slotName = {
                                      'morning': 'Sáng',
                                      'afternoon': 'Trưa',
                                      'evening': 'Tối',
                                    }[slot]!;
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          slotName,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                            color: _themeColors.currentTextSecondaryColor,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        if (meals.isNotEmpty)
                                          ...meals.map((meal) => _buildRecipeTile(meal))
                                        else
                                          Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: _themeColors.currentSurfaceColor,
                                              borderRadius: BorderRadius.circular(12),
                                            ),
                                            child: Text(
                                              'Không có món ăn cho $slotName',
                                              style: TextStyle(
                                                color: _themeColors.currentTextSecondaryColor,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ),
                                        const SizedBox(height: 12),
                                      ],
                                    );
                                  }),
                                ],
                              )
                            else
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: _themeColors.currentSurfaceColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  'Chưa có kế hoạch bữa ăn cho ngày này. Nhấn "Tạo kế hoạch bữa ăn" để bắt đầu.',
                                  style: TextStyle(
                                    color: _themeColors.currentTextSecondaryColor,
                                    fontSize: 14,
                                  ),
                                ),
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
    _headerAnimationController.dispose();
    _httpClient.close();
    super.dispose();
  }
}