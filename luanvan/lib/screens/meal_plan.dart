import 'dart:async';
import 'dart:convert';
import 'package:fl_chart/fl_chart.dart';
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

  Color get primary => isDarkMode ? Colors.blue[700] ?? Colors.blue : Colors.blue[500] ?? Colors.blue;
  Color get accent => isDarkMode ? Colors.cyan[600] ?? Colors.cyan : Colors.cyan[400] ?? Colors.cyan;
  Color get secondary => isDarkMode ? Colors.grey[600] ?? Colors.grey : Colors.grey[400] ?? Colors.grey;
  Color get error => isDarkMode ? Colors.red[400] ?? Colors.red : Colors.red[600] ?? Colors.red;
  Color get warning => isDarkMode ? Colors.amber[400] ?? Colors.amber : Colors.amber[600] ?? Colors.amber;
  Color get success => isDarkMode ? Colors.green[400] ?? Colors.green : Colors.green[600] ?? Colors.green;
  Color get background => isDarkMode ? Colors.grey[900] ?? Colors.black : Colors.white;
  Color get surface => isDarkMode ? Colors.grey[800] ?? Colors.grey : Colors.grey[50] ?? Colors.white;
  Color get textPrimary => isDarkMode ? Colors.white : Colors.grey[900] ?? Colors.black;
  Color get textSecondary => isDarkMode ? Colors.grey[400] ?? Colors.grey : Colors.grey[600] ?? Colors.grey;
}

class MealPlanScreen extends StatefulWidget {
  final String userId;
  final bool isDarkMode;
  final String? fridgeId;

  const MealPlanScreen({
    super.key,
    required this.userId,
    required this.isDarkMode,
    this.fridgeId,
  });

  @override
  State<MealPlanScreen> createState() => _MealPlanScreenState();
}

class _MealPlanScreenState extends State<MealPlanScreen> with TickerProviderStateMixin {
  late final AnimationController _animationController;
  late final AnimationController _headerAnimationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<Offset> _headerSlideAnimation;

  final Map<String, Map<String, List<Map<String, dynamic>>>> _mealPlan = {};
  final Map<String, List<String>> _seenRecipeIds = {'week': []};
  final Map<String, List<Map<String, dynamic>>> _allCalendarMeals = {};
  final Set<String> _favoriteRecipeIds = {};
  final Set<String> _calendarDaysWithRecipes = {};
  final Map<String, bool> _addedToCalendar = {};
  final Map<String, bool> _dayLoading = {};
  final Map<String, Map<String, dynamic>> _recipeCache = {};
  final List<Map<String, dynamic>> _userFridges = [];
  String? _selectedFridgeId;

  bool _isLoading = false;
  bool _showAdvancedOptions = false;
  String? _errorMessage;
  String? _selectedDiet;
  String _selectedTimeFrame = 'week';
  int _targetCalories = 2000;
  bool _useFridgeIngredients = false;
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();

  static const _diets = ['Vegetarian', 'Vegan', 'Gluten Free', 'Ketogenic', 'Pescatarian'];
  static const _timeFrames = ['day', 'week'];
  static const _timeFrameTranslations = {
    'day': '1 Ngày',
    'week': 'Tuần',
  };
  static const _maxCacheSize = 100;

  final String _ngrokUrl = Config.getNgrokUrl();
  final Logger _logger = Logger();
  final http.Client _httpClient = http.Client();

  ThemeColors get _theme => ThemeColors(isDarkMode: widget.isDarkMode);

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _initializeLocale();
    _initializeData();
    _loadUserFridges();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _headerAnimationController.dispose();
    _httpClient.close();
    super.dispose();
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

  Future<void> _initializeLocale() async {
    try {
      await initializeDateFormatting('vi_VN', null);
    } catch (e, stackTrace) {
      _logger.e('Failed to initialize locale: $e', stackTrace: stackTrace);
    }
  }

  Future<void> _initializeData() async {
    await _executeWithLoading(
          () async {
        await Future.wait([
          _loadFavoriteRecipes(),
          _loadAllCalendarMeals(),
        ]);
      },
      errorMessage: 'Không thể khởi tạo dữ liệu.',
    );
  }

  Future<void> _loadUserFridges() async {
    await _executeWithLoading(
          () async {
        final response = await _httpClient.get(
          Uri.parse('$_ngrokUrl/get_user_fridges?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final fridges = List<Map<String, dynamic>>.from(data['fridges'] ?? []);
          if (mounted) {
            setState(() {
              _userFridges
                ..clear()
                ..addAll(fridges.map((fridge) => {
                  'fridgeId': fridge['fridgeId']?.toString() ?? '',
                  'name': fridge['fridgeName']?.toString() ?? fridge['name']?.toString() ?? 'Tủ lạnh ${fridge['fridgeId'] ?? 'không tên'}',
                }));
              if (widget.fridgeId != null) {
                _selectedFridgeId = widget.fridgeId;
              } else if (_userFridges.isNotEmpty) {
                _selectedFridgeId = _userFridges.first['fridgeId'] as String?;
              } else {
                _selectedFridgeId = null;
              }
            });
          }
          _logger.i('Đã tải ${_userFridges.length} tủ lạnh cho userId: ${widget.userId}');
        } else {
          throw Exception('Không thể tải danh sách tủ lạnh: ${response.statusCode}');
        }
      },
      errorMessage: 'Không thể tải danh sách tủ lạnh.',
    );
  }

  Future<void> _loadFavoriteRecipes() async {
    await _executeWithLoading(
          () async {
        final response = await _httpClient.get(
          Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final favorites = List<Map<String, dynamic>>.from(data['favoriteRecipes'] ?? []);
          if (mounted) {
            setState(() {
              _favoriteRecipeIds
                ..clear()
                ..addAll(favorites.map((r) => r['recipeId']?.toString() ?? '').where((id) => id.isNotEmpty));
            });
          }
          _logger.i('Đã tải ${favorites.length} công thức yêu thích');
        } else {
          throw Exception('Không thể tải công thức yêu thích: ${response.statusCode}');
        }
      },
      errorMessage: 'Không thể tải công thức yêu thích.',
    );
  }

  Future<List<Map<String, dynamic>>> _fetchFridgeIngredients() async {
    if (!_useFridgeIngredients || _selectedFridgeId == null) return [];

    try {
      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/get_user_ingredients'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': widget.userId,
          'fridgeId': _selectedFridgeId,
        }),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<Map<String, dynamic>>.from(data['ingredients'] ?? []);
      }
      throw Exception('Không thể lấy nguyên liệu: ${response.statusCode}');
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi lấy nguyên liệu: $e', stackTrace: stackTrace);
      return [];
    }
  }

  Future<void> _loadAllCalendarMeals() async {
    await _executeWithLoading(
          () async {
        final response = await _httpClient.get(
          Uri.parse('$_ngrokUrl/get_all_calendar_meals?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final mealsByDate = <String, List<Map<String, dynamic>>>{};
          final daysWithRecipes = <String>{};

          for (var meal in (data['meals'] as List<dynamic>? ?? [])) {
            final date = meal['date'] as String? ?? '';
            if (date.isNotEmpty) {
              mealsByDate[date] = List<Map<String, dynamic>>.from(meal['meals'] ?? []);
              daysWithRecipes.add(date);
              _addedToCalendar[date] = true;
            }
          }

          if (mounted) {
            setState(() {
              _allCalendarMeals
                ..clear()
                ..addAll(mealsByDate);
              _calendarDaysWithRecipes
                ..clear()
                ..addAll(daysWithRecipes);
            });
          }
          _logger.i('Đã tải ${_allCalendarMeals.length} ngày có bữa ăn');
        } else {
          throw Exception('Không thể tải lịch bữa ăn: ${response.body}');
        }
      },
      errorMessage: 'Không thể tải lịch bữa ăn.',
    );
  }

  Future<void> _addToCalendar(Map<String, dynamic> recipe) async {
    if (_isLoading) return;

    final selectedDate = await _selectCalendarDate();
    if (selectedDate == null) {
      _showSnackBar('Không chọn ngày.', _theme.warning);
      return;
    }

    await _executeWithLoading(
          () async {
        final dateStr = selectedDate.toIso8601String().split('T')[0];
        final payload = {
          'userId': widget.userId,
          'date': dateStr,
          'meals': [recipe],
        };

        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/add_to_calendar'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );

        if (response.statusCode == 200) {
          if (mounted) {
            setState(() {
              _allCalendarMeals[dateStr] = (_allCalendarMeals[dateStr] ?? [])..add(recipe);
              _calendarDaysWithRecipes.add(dateStr);
              _addedToCalendar[dateStr] = true;
            });
          }
          _showSnackBar('Đã thêm vào lịch cho ngày $dateStr!', _theme.success);
        } else {
          throw Exception('Không thể thêm vào lịch: ${response.body}');
        }
      },
      errorMessage: 'Không thể thêm vào lịch.',
    );
  }

  Future<void> _addDayToCalendar(DateTime date) async {
    final dateKey = date.toIso8601String().split('T')[0];
    if (_dayLoading[dateKey] == true) return;

    await _executeWithLoading(
          () async {
        final mealsForDay = _allCalendarMeals[dateKey] ?? [];
        if (mealsForDay.isEmpty) {
          final meals = _mealPlan['week']?[dateKey] ?? [];
          final response = await _httpClient.post(
            Uri.parse('$_ngrokUrl/add_to_calendar'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'userId': widget.userId,
              'date': dateKey,
              'meals': meals,
            }),
          );

          if (response.statusCode == 200) {
            if (mounted) {
              setState(() {
                _allCalendarMeals[dateKey] = meals;
                _calendarDaysWithRecipes.add(dateKey);
                _addedToCalendar[dateKey] = true;
              });
            }
            _showSnackBar('Đã thêm ngày vào lịch!', _theme.success);
          } else {
            throw Exception('Không thể thêm vào lịch: ${response.body}');
          }
        }
      },
      errorMessage: 'Không thể thêm vào lịch.',
      loadingKey: dateKey,
    );
  }

  Future<void> _addAllToCalendar() async {
    if (_isLoading || _mealPlan['week']!.isEmpty ?? true) {
      _showSnackBar('Không có kế hoạch bữa ăn để thêm.', _theme.warning);
      return;
    }

    final confirm = await _confirmAction(
      title: 'Xác nhận',
      message: 'Thêm toàn bộ kế hoạch ${_selectedTimeFrame == 'week' ? '7 ngày' : '1 ngày'} vào lịch?',
    );

    if (!confirm) return;

    await _executeWithLoading(
          () async {
        final meals = _mealPlan['week']!;
        for (final dateKey in meals.keys) {
          final dayMeals = meals[dateKey]!;
          if (dayMeals.isEmpty) continue;

          if (mounted) {
            setState(() => _dayLoading[dateKey] = true);
          }
          final payload = {
            'userId': widget.userId,
            'date': dateKey,
            'meals': dayMeals,
          };

          final response = await _httpClient.post(
            Uri.parse('$_ngrokUrl/add_to_calendar'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          );

          if (response.statusCode == 200) {
            if (mounted) {
              setState(() {
                _calendarDaysWithRecipes.add(dateKey);
                _allCalendarMeals[dateKey] = dayMeals;
                _addedToCalendar[dateKey] = true;
              });
            }
          } else {
            throw Exception('Không thể thêm ngày $dateKey vào lịch: ${response.body}');
          }
          if (mounted) {
            setState(() => _dayLoading[dateKey] = false);
          }
        }
        _showSnackBar('Đã thêm toàn bộ kế hoạch vào lịch!', _theme.success);
      },
      errorMessage: 'Không thể thêm tất cả vào lịch.',
      clearDayLoading: true,
    );
  }

  Future<void> _deleteCalendarMeal(String date, String recipeId) async {
    await _executeWithLoading(
          () async {
        final response = await _httpClient.delete(
          Uri.parse('$_ngrokUrl/delete_meal_from_calendar?userId=${widget.userId}&date=$date&recipeId=$recipeId'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          if (mounted) {
            setState(() {
              _allCalendarMeals[date]?.removeWhere((meal) => meal['id'].toString() == recipeId);
              if (_allCalendarMeals[date]?.isEmpty ?? true) {
                _allCalendarMeals.remove(date);
                _calendarDaysWithRecipes.remove(date);
                _addedToCalendar[date] = false;
              }
            });
          }
          _showSnackBar('Đã xóa bữa ăn khỏi lịch!', _theme.success);
        } else {
          throw Exception('Không thể xóa bữa ăn: ${response.body}');
        }
      },
      errorMessage: 'Không thể xóa bữa ăn.',
    );
  }

  Future<void> _deleteAllCalendarMeals() async {
    if (_isLoading) return;

    final confirm = await _confirmAction(
      title: 'Xác nhận xóa',
      message: 'Bạn có chắc chắn muốn xóa toàn bộ lịch bữa ăn?',
    );

    if (!confirm) return;

    await _executeWithLoading(
          () async {
        final response = await _httpClient.delete(
          Uri.parse('$_ngrokUrl/delete_all_calendar_meals?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          if (mounted) {
            setState(() {
              _allCalendarMeals.clear();
              _calendarDaysWithRecipes.clear();
              _addedToCalendar.clear();
              _mealPlan['week']?.clear();
            });
          }
          _showSnackBar('Đã xóa toàn bộ lịch bữa ăn!', _theme.success);
        } else {
          throw Exception('Không thể xóa lịch: ${response.body}');
        }
      },
      errorMessage: 'Không thể xóa lịch.',
    );
  }

  Future<void> _removeDayFromCalendar(DateTime day) async {
    final dateKey = day.toIso8601String().split('T')[0];
    if (!_calendarDaysWithRecipes.contains(dateKey)) {
      _showSnackBar('Ngày này không có trong lịch.', _theme.warning);
      return;
    }

    await _executeWithLoading(
          () async {
        final response = await _httpClient.delete(
          Uri.parse('$_ngrokUrl/delete_meal_from_calendar?userId=${widget.userId}&date=$dateKey'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          if (mounted) {
            setState(() {
              _calendarDaysWithRecipes.remove(dateKey);
              _allCalendarMeals.remove(dateKey);
              _addedToCalendar[dateKey] = false;
            });
          }
          _showSnackBar('Đã xóa ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)} khỏi lịch!', _theme.success);
        } else {
          throw Exception('Không thể xóa khỏi lịch: ${response.body}');
        }
      },
      errorMessage: 'Không thể xóa khỏi lịch.',
    );
  }

  Future<void> _generateWeeklyMealPlan() async {
    if (_isLoading) return;

    await _executeWithLoading(
          () async {
        final ingredients = _useFridgeIngredients && _selectedFridgeId != null ? await _fetchFridgeIngredients() : [];
        final payload = {
          'userId': widget.userId,
          'diet': _selectedDiet ?? '',
          'maxCalories': _targetCalories,
          'timeFrame': _selectedTimeFrame,
          'useFridgeIngredients': _useFridgeIngredients,
          'ingredients': ingredients,
        };

        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/generate_weekly_meal_plan'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final mealPlanData = List<dynamic>.from(data['mealPlan'] ?? []);
          final processedWeek = <String, List<Map<String, dynamic>>>{};

          for (var day in mealPlanData) {
            final date = day['day'] as String? ?? '';
            if (date.isEmpty) continue;
            final meals = day['meals'] as Map<String, dynamic>? ?? {};
            processedWeek[date] = [];
            _addedToCalendar[date] = false;

            for (var timeSlot in ['morning', 'afternoon', 'evening']) {
              final recipes = List<dynamic>.from(meals[timeSlot] ?? []);
              for (var recipe in recipes) {
                final recipeId = recipe['id']?.toString() ?? 'fallback_${DateTime.now().millisecondsSinceEpoch}';
                processedWeek[date]!.add({
                  'id': recipeId,
                  'title': recipe['title']?.toString() ?? 'Không có tiêu đề',
                  'image': recipe['image']?.toString() ?? '',
                  'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
                  'ingredientsUsed': (recipe['ingredientsUsed'] ?? []).map<Map<String, dynamic>>((e) => ({
                    'name': e['name']?.toString() ?? '',
                    'amount': e['amount'] ?? 0,
                    'unit': e['unit']?.toString() ?? '',
                  })).toList(),
                  'ingredientsMissing': (recipe['ingredientsMissing'] ?? []).map<Map<String, dynamic>>((e) => ({
                    'name': e['name']?.toString() ?? '',
                    'amount': e['amount'] ?? 0,
                    'unit': e['unit']?.toString() ?? '',
                  })).toList(),
                  'extendedIngredients': (recipe['extendedIngredients'] ?? []).map<Map<String, dynamic>>((e) => ({
                    'name': e['name']?.toString() ?? '',
                    'amount': e['amount'] ?? 0,
                    'unit': e['unit']?.toString() ?? '',
                  })).toList(),
                  'instructions': recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
                  'nutrition': recipe['nutrition'] ?? [],
                  'isFavorite': _favoriteRecipeIds.contains(recipeId),
                  'timeSlot': timeSlot,
                  'diets': recipe['diets'] ?? [],
                  'relevanceScore': recipe['relevanceScore']?.toDouble() ?? 0.0,
                });
              }
            }
          }

          if (mounted) {
            setState(() {
              _mealPlan['week'] = processedWeek;
              _seenRecipeIds['week'] = processedWeek.values.expand((e) => e).map((r) => r['id'].toString()).toList();
              if (processedWeek.isNotEmpty) {
                try {
                  _selectedDay = DateTime.parse(processedWeek.keys.first);
                  _focusedDay = _selectedDay;
                } catch (e) {
                  _logger.e('Lỗi phân tích ngày: $e');
                  _selectedDay = DateTime.now();
                  _focusedDay = _selectedDay;
                }
              }
            });
          }
          _showSnackBar(
            'Đã tạo kế hoạch ${_timeFrameTranslations[_selectedTimeFrame]} với ${processedWeek.values.fold<int>(0, (sum, e) => sum + e.length)} công thức!',
            _theme.success,
          );
        } else {
          throw Exception('Không thể tạo kế hoạch bữa ăn: ${response.statusCode}');
        }
      },
      errorMessage: 'Không thể tạo kế hoạch bữa ăn.',
      clearError: true,
    );
  }

  Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
    await _executeWithLoading(
          () async {
        if (isFavorite) {
          final response = await _httpClient.delete(
            Uri.parse('$_ngrokUrl/delete_favorite_recipe/$recipeId'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'userId': widget.userId}),
          );

          if (response.statusCode == 200) {
            if (mounted) {
              setState(() {
                _favoriteRecipeIds.remove(recipeId);
                _updateMealPlanFavoriteStatus(recipeId, false);
              });
            }
            _showSnackBar('Đã xóa khỏi danh sách yêu thích!', _theme.success);
          } else {
            throw Exception('Không thể xóa công thức yêu thích: ${response.statusCode}');
          }
        } else {
          final meals = _mealPlan['week'];
          if (meals == null) throw Exception('Kế hoạch bữa ăn chưa được khởi tạo');

          final recipe = meals.values.expand((e) => e).firstWhere((r) => r['id'].toString() == recipeId, orElse: () => {});
          if (recipe.isEmpty) throw Exception('Không tìm thấy công thức');

          final payload = {
            'userId': widget.userId,
            'recipeId': recipeId,
            'title': recipe['title']?.toString() ?? 'Không có tiêu đề',
            'imageUrl': recipe['image']?.toString() ?? '',
            'instructions': recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
            'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
            'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
            'extendedIngredients': recipe['extendedIngredients'] ?? [],
            'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
            'timeSlot': recipe['timeSlot']?.toString() ?? 'other',
            'nutrition': recipe['nutrition'] ?? [],
            'diets': recipe['diets'] ?? [],
            'relevanceScore': recipe['relevanceScore']?.toDouble() ?? 0.0,
          };

          final response = await _httpClient.post(
            Uri.parse('$_ngrokUrl/add_favorite_recipe'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          );

          if (response.statusCode == 200) {
            if (mounted) {
              setState(() {
                _favoriteRecipeIds.add(recipeId);
                _updateMealPlanFavoriteStatus(recipeId, true);
              });
            }
            _showSnackBar('Đã thêm vào danh sách yêu thích!', _theme.success);
          } else {
            throw Exception('Không thể thêm công thức yêu thích: ${response.statusCode}');
          }
        }
      },
      errorMessage: 'Không thể cập nhật trạng thái yêu thích.',
    );
  }

  void _updateMealPlanFavoriteStatus(String recipeId, bool isFavorite) {
    _mealPlan['week']?.values.forEach((dayMeals) {
      final recipeIndex = dayMeals.indexWhere((r) => r['id'].toString() == recipeId);
      if (recipeIndex != -1) {
        dayMeals[recipeIndex]['isFavorite'] = isFavorite;
      }
    });
  }

  Future<void> _addToShoppingList(Map<String, dynamic> recipe) async {
    await _executeWithLoading(
          () async {
        final missingIngredients = (recipe['ingredientsMissing'] as List<dynamic>?)?.map<Map<String, dynamic>>((e) => ({
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? '',
        })).toList() ?? [];

        if (missingIngredients.isEmpty) {
          _showSnackBar('Không có nguyên liệu để thêm.', _theme.success);
          return;
        }

        final payload = {
          'userId': widget.userId,
          'items': missingIngredients,
        };

        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/place_order'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );

        if (response.statusCode == 200) {
          _showSnackBar('Đã thêm ${missingIngredients.length} nguyên liệu vào danh sách mua sắm!', _theme.success);
        } else {
          throw Exception('Không thể thêm vào danh sách mua sắm: ${response.statusCode}');
        }
      },
      errorMessage: 'Không thể thêm vào danh sách mua sắm.',
    );
  }

  Future<Map<String, dynamic>> _fetchMealDetails(String id) async {
    if (_recipeCache.containsKey(id)) return _recipeCache[id]!;

    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/recipes/$id/information'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>? ?? {};
        final recipeData = {
          'id': data['id']?.toString() ?? id,
          'title': data['title']?.toString() ?? 'Không xác định',
          'image': data['image']?.toString() ?? '',
          'readyInMinutes': data['readyInMinutes']?.toString() ?? 'N/A',
          'ingredientsUsed': (data['ingredientsUsed'] ?? []).map<Map<String, dynamic>>((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList(),
          'ingredientsMissing': (data['ingredientsMissing'] ?? []).map<Map<String, dynamic>>((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList(),
          'extendedIngredients': (data['extendedIngredients'] ?? []).map<Map<String, dynamic>>((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList(),
          'instructions': data['instructions'] is List
              ? (data['instructions'] as List).join('\n')
              : data['instructions']?.toString() ?? 'Không có hướng dẫn chi tiết.',
          'nutrition': (data['nutrition'] ?? []).map<Map<String, dynamic>>((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList(),
          'diets': data['diets'] as List<dynamic>? ?? [],
          'relevanceScore': data['relevanceScore']?.toDouble() ?? 0.0,
        };
        if (_recipeCache.length >= _maxCacheSize) {
          _recipeCache.remove(_recipeCache.keys.first);
        }
        _recipeCache[id] = recipeData;
        return recipeData;
      }
      throw Exception('Không thể tải chi tiết công thức: $id, trạng thái: ${response.statusCode}');
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải chi tiết công thức: $e', stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _showRecipeDetails(Map<String, dynamic> recipe) async {
    if (recipe['id'] == null || recipe['title'] == null) {
      _showSnackBar('Dữ liệu công thức không hợp lệ.', _theme.error);
      return;
    }

    var detailedRecipe = Map<String, dynamic>.from(recipe);
    await _executeWithLoading(
          () async {
        if (detailedRecipe['instructions'] == null ||
            detailedRecipe['nutrition'] == null ||
            (detailedRecipe['ingredientsUsed']?.isEmpty ?? true) &&
                (detailedRecipe['ingredientsMissing']?.isEmpty ?? true) &&
                (detailedRecipe['extendedIngredients']?.isEmpty ?? true)) {
          detailedRecipe = {
            ...recipe,
            ...await _fetchMealDetails(recipe['id'].toString()),
            'instructions': recipe['instructions']?.toString() ?? 'Không có hướng dẫn chi tiết.',
            'nutrition': recipe['nutrition'] ?? [
              {'name': 'Calories', 'amount': 0, 'unit': 'kcal'},
              {'name': 'Fat', 'amount': 0, 'unit': 'g'},
              {'name': 'Carbohydrates', 'amount': 0, 'unit': 'g'},
              {'name': 'Protein', 'amount': 0, 'unit': 'g'},
            ],
            'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
            'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
            'extendedIngredients': recipe['extendedIngredients'] ?? [],
            'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
            'title': recipe['title']?.toString() ?? 'Không có tiêu đề',
            'image': recipe['image']?.toString() ?? '',
            'diets': recipe['diets'] ?? [],
            'relevanceScore': recipe['relevanceScore']?.toDouble() ?? 0.0,
          };
        }

        if (detailedRecipe['instructions'] is List) {
          detailedRecipe['instructions'] = (detailedRecipe['instructions'] as List).join('\n');
        }
      },
      errorMessage: 'Không thể tải chi tiết công thức.',
    );

    final requiredIngredients = <String>[
      ...?(recipe['ingredientsUsed'] as List<dynamic>?)?.map((e) => '${e['name']?.toString() ?? 'Không xác định'} (${e['amount']?.toString() ?? '0'} ${e['unit']?.toString() ?? ''})').toList() ?? [],
      ...?(recipe['ingredientsMissing'] as List<dynamic>?)?.map((e) => '${e['name']?.toString() ?? 'Không xác định'} (${e['amount']?.toString() ?? '0'} ${e['unit']?.toString() ?? ''})').toList() ?? [],
      if ((recipe['ingredientsUsed']?.isEmpty ?? true) &&
          (recipe['ingredientsMissing']?.isEmpty ?? true) &&
          (recipe['extendedIngredients']?.isNotEmpty ?? false))
        ...(recipe['extendedIngredients'] as List<dynamic>?)?.map((e) => '${e['name']?.toString() ?? 'Không xác định'} (${e['amount']?.toString() ?? '0'} ${e['unit']?.toString() ?? ''})').toList() ?? [],
    ];

    if (mounted) {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.85,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: true,
          builder: (context, scrollController) => _RecipeDetailsSheet(
            recipe: detailedRecipe,
            theme: _theme,
            isLoading: _isLoading,
            onToggleFavorite: () => _toggleFavorite(detailedRecipe['id'].toString(), detailedRecipe['isFavorite'] == true),
            onAddToCalendar: () => _addToCalendar(detailedRecipe),
            onAddToShoppingList: () => _addToShoppingList(detailedRecipe),
            onRemoveFromCalendar: () => _removeDayFromCalendar(_selectedDay),
            requiredIngredients: requiredIngredients,
            buildNutritionSection: _buildNutritionSection,
            buildIngredientsSection: _buildIngredientsSection,
          ),
        ),
      );
    }
  }

  Future<void> _showRecipesForDay(DateTime day) async {
    final dateKey = day.toIso8601String().split('T')[0];
    var meals = _allCalendarMeals[dateKey] ?? [];

    if (meals.isEmpty && _calendarDaysWithRecipes.contains(dateKey)) {
      await _executeWithLoading(
            () async {
          final response = await _httpClient.get(
            Uri.parse('$_ngrokUrl/get_calendar_meals?userId=${widget.userId}&date=$dateKey'),
            headers: {'Content-Type': 'application/json'},
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            meals = List<Map<String, dynamic>>.from(data['meals'] ?? []);
            if (mounted) {
              setState(() {
                _allCalendarMeals[dateKey] = meals;
              });
            }
          } else {
            throw Exception('Không thể tải công thức lịch: ${response.body}');
          }
        },
        errorMessage: 'Không thể tải công thức lịch.',
      );
    }

    if (meals.isEmpty) {
      _showSnackBar('Không có công thức cho ngày này trong lịch.', _theme.warning);
      return;
    }

    if (mounted) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          expand: true,
          builder: (context, scrollController) => _DayRecipesSheet(
            day: day,
            meals: meals,
            theme: _theme,
            isLoading: _isLoading,
            onRecipeTap: _showRecipeDetails,
          ),
        ),
      );
    }
  }

  void _showCalendar() {
    _loadAllCalendarMeals().then((_) {
      if (mounted) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (context) => DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.5,
            maxChildSize: 0.9,
            expand: false,
            builder: (context, scrollController) => _CalendarSheet(
              meals: _allCalendarMeals,
              theme: _theme,
              isLoading: _isLoading,
              calendarDaysWithRecipes: _calendarDaysWithRecipes,
              onRecipeTap: _showRecipeDetails,
              onAddToCalendar: _addToCalendar,
              onDeleteMeal: _deleteCalendarMeal,
              onDeleteDay: _removeDayFromCalendar,
            ),
          ),
        );
      }
    });
  }

  Future<DateTime?> _selectCalendarDate() async {
    return showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      builder: (context, child) => Theme(
        data: ThemeData(
          colorScheme: ColorScheme.light(
            primary: _theme.primary,
            onPrimary: Colors.white,
            surface: _theme.surface,
            onSurface: _theme.textPrimary,
          ),
        ),
        child: child!,
      ),
    );
  }

  Future<bool> _confirmAction({required String title, required String message}) async {
    return (await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _theme.surface,
        title: Text(title, style: TextStyle(color: _theme.textPrimary)),
        content: Text(message, style: TextStyle(color: _theme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: _theme.secondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Xác nhận', style: TextStyle(color: _theme.error)),
          ),
        ],
      ),
    )) ??
        false;
  }

  Future<void> _executeWithLoading(
      Future<void> Function() action, {
        String? errorMessage,
        String? loadingKey,
        bool clearError = false,
        bool clearDayLoading = false,
      }) async {
    if (mounted) {
      setState(() {
        if (loadingKey != null) {
          _dayLoading[loadingKey] = true;
        } else {
          _isLoading = true;
        }
        if (clearError) _errorMessage = null;
      });
    }

    try {
      await action();
    } catch (e, stackTrace) {
      _logger.e('Lỗi: $e', stackTrace: stackTrace);
      if (errorMessage != null && mounted) {
        _showSnackBar(errorMessage, _theme.error);
      }
    } finally {
      if (mounted) {
        setState(() {
          if (loadingKey != null) {
            _dayLoading[loadingKey] = false;
          } else {
            _isLoading = false;
          }
          if (clearDayLoading) _dayLoading.clear();
        });
      }
    }
  }

  void _showSnackBar(String message, Color backgroundColor) {
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                backgroundColor == _theme.error ? Icons.error_outline : Icons.check_circle_outline,
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
  }

  Widget _buildRecipeTile(Map<String, dynamic> recipe) {
    final recipeId = recipe['id']?.toString() ?? '';
    final isFavorite = _favoriteRecipeIds.contains(recipeId);

    return Dismissible(
      key: Key(recipeId),
      direction: DismissDirection.horizontal,
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          color: _theme.success,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.calendar_today, color: Colors.white),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: _theme.error,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await _addToCalendar(recipe);
          return false;
        }
        return await _confirmAction(
          title: 'Xác nhận xóa',
          message: 'Xóa "${recipe['title'] ?? 'Không có tiêu đề'}" khỏi kế hoạch?',
        );
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          final dateKey = _selectedDay.toIso8601String().split('T')[0];
          _deleteCalendarMeal(dateKey, recipeId);
        }
      },
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        leading: _RecipeImage(imageUrl: recipe['image']?.toString(), theme: _theme),
        title: Text(
          recipe['title']?.toString() ?? 'Không có tiêu đề',
          style: TextStyle(
            color: _theme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          recipe['timeSlot'] != null
              ? {'morning': 'Sáng', 'afternoon': 'Trưa', 'evening': 'Tối'}[recipe['timeSlot']] ?? 'Khác'
              : 'Không xác định',
          style: TextStyle(
            color: _theme.textSecondary,
            fontSize: 12,
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? _theme.error : _theme.textSecondary,
            size: 20,
          ),
          onPressed: _isLoading ? null : () => _toggleFavorite(recipeId, isFavorite),
        ),
        onTap: () => _showRecipeDetails(recipe),
      ),
    );
  }

  Widget _buildIngredientsSection(String title, List<String> items, [Color? color, IconData? icon]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon ?? Icons.check_circle, color: color ?? _theme.primary, size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: _theme.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _theme.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'Không có nguyên liệu',
              style: TextStyle(color: _theme.textSecondary, fontSize: 14),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, index) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: (color ?? _theme.primary).withAlpha(26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: (color ?? _theme.primary).withAlpha(77)),
              ),
              child: Row(
                children: [
                  Icon(Icons.circle, color: color ?? _theme.primary, size: 10),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      items[index],
                      style: TextStyle(color: _theme.textPrimary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildNutritionSection(List<dynamic> nutrients) {
    const keyNutrients = ['Calories', 'Fat', 'Carbohydrates', 'Protein'];
    const chartHeight = 200.0;
    const maxYScaleFactor = 1.2;

    final nutrientColors = [_theme.primary, _theme.accent, _theme.success, _theme.secondary];
    final filteredNutrients = nutrients
        .where((n) => n is Map<String, dynamic> &&
        keyNutrients.contains(n['name']) &&
        n['amount'] is num &&
        n['amount'] > 0 &&
        n['unit'] is String)
        .toList();

    final nutrientData = {
      for (var nutrient in keyNutrients)
        nutrient: (filteredNutrients.firstWhere(
              (n) => n['name'] == nutrient,
          orElse: () => {'amount': 0.0, 'unit': nutrient == 'Calories' ? 'kcal' : 'g'},
        )['amount'] as num)
            .toDouble(),
    };

    if (filteredNutrients.isEmpty || nutrientData.values.every((value) => value == 0.0)) {
      return Text(
        'Không có dữ liệu dinh dưỡng hợp lệ',
        style: TextStyle(fontSize: _getFontSize(context, 13), color: _theme.textSecondary),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final fontSize = _getFontSize(context, 12);
    final barWidth = screenWidth < 400 ? 16.0 : 20.0;
    final maxY = nutrientData.values.reduce((a, b) => a > b ? a : b) * maxYScaleFactor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dinh dưỡng',
          style: TextStyle(
            fontSize: _getFontSize(context, 16),
            fontWeight: FontWeight.bold,
            color: _theme.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          height: chartHeight,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: _theme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _theme.secondary, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(_theme.isDarkMode ? 77 : 13),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: maxY,
              barGroups: keyNutrients.asMap().entries.map((entry) {
                final index = entry.key;
                final nutrient = entry.value;
                return BarChartGroupData(
                  x: index,
                  barRods: [
                    BarChartRodData(
                      toY: nutrientData[nutrient]!,
                      color: nutrientColors[index],
                      width: barWidth,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      backDrawRodData: BackgroundBarChartRodData(
                        show: true,
                        toY: maxY,
                        color: _theme.background,
                      ),
                    ),
                  ],
                );
              }).toList(),
              titlesData: FlTitlesData(
                show: true,
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index >= 0 && index < keyNutrients.length) {
                        final label = keyNutrients[index] == 'Carbohydrates' ? 'Carbs' : keyNutrients[index];
                        return Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            label == 'Calories'
                                ? 'Calo'
                                : label == 'Fat'
                                ? 'Chất béo'
                                : label == 'Carbohydrates'
                                ? 'Tinh bột'
                                : 'Chất đạm',
                            style: TextStyle(
                              color: _theme.textPrimary,
                              fontSize: fontSize,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }
                      return const Text('');
                    },
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 40,
                    getTitlesWidget: (value, meta) => Text(
                      value.toInt().toString(),
                      style: TextStyle(color: _theme.textSecondary, fontSize: fontSize),
                    ),
                  ),
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border.all(color: _theme.secondary, width: 1),
              ),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: _theme.secondary,
                  strokeWidth: 1,
                ),
              ),
              barTouchData: BarTouchData(
                enabled: true,
                touchTooltipData: BarTouchTooltipData(
                  tooltipRoundedRadius: 8,
                  tooltipPadding: const EdgeInsets.all(8),
                  tooltipMargin: 8,
                  getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    final unit = filteredNutrients[groupIndex]['unit'] as String;
                    final nutrientName = keyNutrients[groupIndex];
                    final translatedName = nutrientName == 'Calories'
                        ? 'Calo'
                        : nutrientName == 'Fat'
                        ? 'Chất béo'
                        : nutrientName == 'Carbohydrates'
                        ? 'Tinh bột'
                        : 'Chất đạm';
                    return BarTooltipItem(
                      '$translatedName: ${rod.toY.toStringAsFixed(1)} $unit',
                      TextStyle(
                        color: _theme.textPrimary,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  },
                ),
                touchCallback: (event, response) {
                  if (!event.isInterestedForInteractions || response?.spot == null) return;
                  final index = response!.spot!.touchedBarGroupIndex;
                  if (index >= 0 && index < keyNutrients.length) {
                    final unit = filteredNutrients[index]['unit'] as String;
                    final nutrientName = keyNutrients[index];
                    final translatedName = nutrientName == 'Calories'
                        ? 'Calo'
                        : nutrientName == 'Fat'
                        ? 'Chất béo'
                        : nutrientName == 'Carbohydrates'
                        ? 'Tinh bột'
                        : 'Chất đạm';
                    _showSnackBar(
                      '$translatedName: ${nutrientData[keyNutrients[index]]!.toStringAsFixed(1)} $unit',
                      _theme.success,
                    );
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        ...filteredNutrients.map((nutrient) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                nutrient['name'] == 'Calories'
                    ? 'Calo'
                    : nutrient['name'] == 'Fat'
                    ? 'Chất béo'
                    : nutrient['name'] == 'Carbohydrates'
                    ? 'Tinh bột'
                    : 'Chất đạm',
                style: TextStyle(fontSize: _getFontSize(context, 13), color: _theme.textPrimary),
              ),
              Text(
                '${(nutrient['amount'] as num).toStringAsFixed(1)} ${nutrient['unit']}',
                style: TextStyle(fontSize: _getFontSize(context, 13), color: _theme.textPrimary),
              ),
            ],
          ),
        )),
      ],
    );
  }

  double _getFontSize(BuildContext context, double baseSize) {
    final screenWidth = MediaQuery.of(context).size.width;
    return screenWidth < 400 ? baseSize - 2 : baseSize;
  }

  @override
  Widget build(BuildContext context) {
    final meals = _mealPlan['week'] ?? {};
    final dateKey = _selectedDay.toIso8601String().split('T')[0];
    final mealsForSelectedDay = meals[dateKey] ?? [];
    final isDayInCalendar = _calendarDaysWithRecipes.contains(dateKey);

    return Scaffold(
      backgroundColor: _theme.background,
      appBar: AppBar(
        backgroundColor: _theme.surface,
        elevation: 0,
        title: SlideTransition(
          position: _headerSlideAnimation,
          child: Text(
            'Kế hoạch bữa ăn',
            style: TextStyle(
              color: _theme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.calendar_today, color: _theme.primary),
            onPressed: _showCalendar,
            tooltip: 'Xem lịch bữa ăn',
          ),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: Column(
          children: [
            _HeaderSection(
              theme: _theme,
              isLoading: _isLoading,
              selectedTimeFrame: _selectedTimeFrame,
              selectedDiet: _selectedDiet,
              targetCalories: _targetCalories,
              showAdvancedOptions: _showAdvancedOptions,
              useFridgeIngredients: _useFridgeIngredients,
              selectedFridgeId: _selectedFridgeId,
              userFridges: _userFridges,
              timeFrameTranslations: _timeFrameTranslations,
              diets: _diets,
              onTimeFrameChanged: (value) => setState(() => _selectedTimeFrame = value ?? 'week'),
              onDietChanged: (value) => setState(() => _selectedDiet = value),
              onCaloriesChanged: (value) => setState(() => _targetCalories = int.tryParse(value) ?? 2000),
              onToggleAdvancedOptions: () => setState(() => _showAdvancedOptions = !_showAdvancedOptions),
              onUseFridgeChanged: (value) => setState(() {
                _useFridgeIngredients = value ?? false;
                if (!_useFridgeIngredients) _selectedFridgeId = null;
              }),
              onFridgeChanged: (value) => setState(() => _selectedFridgeId = value),
              onGeneratePlan: _generateWeeklyMealPlan,
              onAddAllToCalendar: _addAllToCalendar,
              onDeleteAllCalendar: _deleteAllCalendarMeals,
              focusedDay: _focusedDay,
              selectedDay: _selectedDay,
              calendarDaysWithRecipes: _calendarDaysWithRecipes,
              onDaySelected: (selectedDay, focusedDay) {
                setState(() {
                  _selectedDay = selectedDay;
                  _focusedDay = focusedDay;
                });
                _showRecipesForDay(selectedDay);
              },
            ),
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                color: _theme.error.withOpacity(0.1),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: _theme.error, fontSize: 14),
                ),
              ),
            Expanded(
              child: _isLoading
                  ? _ShimmerList(theme: _theme)
                  : mealsForSelectedDay.isEmpty
                  ? _EmptyState(
                theme: _theme,
                showCalendarButton: _calendarDaysWithRecipes.contains(dateKey),
                onShowCalendar: () => _showRecipesForDay(_selectedDay),
              )
                  : ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: mealsForSelectedDay.length,
                itemBuilder: (context, index) => _buildRecipeTile(mealsForSelectedDay[index]),
              ),
            ),
            if (mealsForSelectedDay.isNotEmpty && !isDayInCalendar)
              _FooterActions(
                theme: _theme,
                isLoading: _dayLoading[dateKey] ?? false,
                onAddToCalendar: () => _addDayToCalendar(_selectedDay),
                onRemoveFromCalendar: () => _removeDayFromCalendar(_selectedDay),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecipeImage extends StatelessWidget {
  final String? imageUrl;
  final ThemeColors theme;

  const _RecipeImage({required this.imageUrl, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.surface,
      ),
      child: imageUrl?.isNotEmpty ?? false
          ? ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          imageUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Icon(
            Icons.restaurant,
            color: theme.primary,
            size: 24,
          ),
        ),
      )
          : Icon(
        Icons.restaurant,
        color: theme.primary,
        size: 24,
      ),
    );
  }
}

class _RecipeDetailsSheet extends StatelessWidget {
  final Map<String, dynamic> recipe;
  final ThemeColors theme;
  final bool isLoading;
  final VoidCallback onToggleFavorite;
  final VoidCallback onAddToCalendar;
  final VoidCallback onAddToShoppingList;
  final VoidCallback onRemoveFromCalendar;
  final List<String> requiredIngredients;
  final Widget Function(List<dynamic>) buildNutritionSection;
  final Widget Function(String, List<String>, [Color?, IconData?]) buildIngredientsSection;

  const _RecipeDetailsSheet({
    required this.recipe,
    required this.theme,
    required this.isLoading,
    required this.onToggleFavorite,
    required this.onAddToCalendar,
    required this.onAddToShoppingList,
    required this.onRemoveFromCalendar,
    required this.requiredIngredients,
    required this.buildNutritionSection,
    required this.buildIngredientsSection,
  });

  @override
  Widget build(BuildContext context) {
    double getFontSize(double baseSize) {
      return MediaQuery.of(context).size.width < 400 ? baseSize - 2 : baseSize;
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
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
                color: theme.isDarkMode ? Colors.grey[400]! : Colors.grey[300]!,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            TabBar(
              labelColor: theme.primary,
              unselectedLabelColor: theme.secondary,
              indicatorColor: theme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.info_outline, size: 16),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Tổng quan',
                          style: TextStyle(fontSize: getFontSize(12), overflow: TextOverflow.ellipsis),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.local_dining, size: 16),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Nguyên liệu',
                          style: TextStyle(fontSize: getFontSize(12), overflow: TextOverflow.ellipsis),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.book, size: 16),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Hướng dẫn',
                          style: TextStyle(fontSize: getFontSize(12), overflow: TextOverflow.ellipsis),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today, size: 16),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Lịch',
                          style: TextStyle(fontSize: getFontSize(12), overflow: TextOverflow.ellipsis),
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Expanded(
              child: isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                recipe['title'].toString(),
                                style: TextStyle(
                                  fontSize: getFontSize(20),
                                  fontWeight: FontWeight.bold,
                                  color: theme.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: isLoading
                                  ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                                  : Icon(
                                recipe['isFavorite'] == true ? Icons.favorite : Icons.favorite_border,
                                color: recipe['isFavorite'] == true ? theme.error : theme.textSecondary,
                                size: 20,
                              ),
                              onPressed: isLoading ? null : onToggleFavorite,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Hero(
                          tag: 'recipe_image_${recipe['id']}',
                          child: recipe['image'].toString().isNotEmpty
                              ? Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withAlpha(26),
                                  blurRadius: 5,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                recipe['image'].toString(),
                                height: 160,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                loadingBuilder: (context, child, loadingProgress) {
                                  if (loadingProgress == null) return child;
                                  return SizedBox(
                                    height: 160,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        value: loadingProgress.expectedTotalBytes != null
                                            ? loadingProgress.cumulativeBytesLoaded /
                                            (loadingProgress.expectedTotalBytes ?? 1)
                                            : null,
                                      ),
                                    ),
                                  );
                                },
                                errorBuilder: (context, error, stackTrace) => Container(
                                  height: 160,
                                  color: theme.surface,
                                  child: Icon(
                                    Icons.broken_image,
                                    size: 36,
                                    color: theme.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          )
                              : Container(
                            height: 160,
                            decoration: BoxDecoration(
                              color: theme.surface,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Icon(
                                Icons.restaurant,
                                size: 36,
                                color: theme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.primary.withAlpha(26),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.access_time, color: theme.primary, size: 18),
                              const SizedBox(width: 8),
                              Text(
                                'Thời gian chuẩn bị: ${recipe['readyInMinutes'].toString()} phút',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: theme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        recipe['nutrition']?.isNotEmpty ?? false
                            ? buildNutritionSection(recipe['nutrition'])
                            : Text(
                          'Không có thông tin dinh dưỡng',
                          style: TextStyle(fontSize: 13, color: theme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        buildIngredientsSection('Nguyên liệu cần thiết', requiredIngredients, theme.primary, Icons.local_dining),
                        const SizedBox(height: 12),
                        if (recipe['ingredientsMissing']?.isNotEmpty ?? false)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [theme.accent, theme.primary]),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: ElevatedButton(
                              onPressed: isLoading ? null : onAddToShoppingList,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.add_shopping_cart, color: Colors.white, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    isLoading ? 'Đang thêm...' : 'Thêm vào danh sách mua sắm',
                                    style: const TextStyle(
                                      fontSize: 13,
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
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Text(
                          'Hướng dẫn',
                          style: TextStyle(
                            fontSize: getFontSize(16),
                            fontWeight: FontWeight.bold,
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: theme.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: theme.secondary),
                          ),
                          child: Text(
                            recipe['instructions'].toString(),
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.textPrimary,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quản lý lịch',
                          style: TextStyle(
                            fontSize: getFontSize(16),
                            fontWeight: FontWeight.bold,
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [theme.primary, theme.accent]),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ElevatedButton.icon(
                            onPressed: isLoading ? null : onAddToCalendar,
                            icon: isLoading
                                ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                                : const Icon(Icons.calendar_today, color: Colors.white, size: 18),
                            label: Text(
                              isLoading ? 'Đang thêm...' : 'Thêm vào lịch',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [theme.error, theme.warning]),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ElevatedButton(
                            onPressed: isLoading ? null : onRemoveFromCalendar,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: Text(
                              isLoading ? 'Đang xóa...' : 'Xóa khỏi lịch',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),    ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarSheet extends StatelessWidget {
  final Map<String, List<Map<String, dynamic>>> meals;
  final ThemeColors theme;
  final bool isLoading;
  final Set<String> calendarDaysWithRecipes;
  final Function(Map<String, dynamic>) onRecipeTap;
  final Function(Map<String, dynamic>) onAddToCalendar;
  final Function(String, String) onDeleteMeal;
  final Function(DateTime) onDeleteDay;

  const _CalendarSheet({
    required this.meals,
    required this.theme,
    required this.isLoading,
    required this.calendarDaysWithRecipes,
    required this.onRecipeTap,
    required this.onAddToCalendar,
    required this.onDeleteMeal,
    required this.onDeleteDay,
  });

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final DateTime firstDay = now.subtract(const Duration(days: 365));
    final DateTime lastDay = now.add(const Duration(days: 365));

    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: theme.isDarkMode ? Colors.grey[400]! : Colors.grey[300]!,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : SingleChildScrollView(
              child: Column(
                children: [
                  TableCalendar(
                    firstDay: firstDay,
                    lastDay: lastDay,
                    focusedDay: DateTime.now(),
                    locale: 'vi_VN',
                    headerStyle: HeaderStyle(
                      formatButtonVisible: false,
                      titleCentered: true,
                      titleTextStyle: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    calendarStyle: CalendarStyle(
                      todayDecoration: BoxDecoration(
                        color: theme.primary.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      selectedDecoration: BoxDecoration(
                        color: theme.primary,
                        shape: BoxShape.circle,
                      ),
                      markerDecoration: BoxDecoration(
                        color: theme.accent,
                        shape: BoxShape.circle,
                      ),
                      outsideTextStyle: TextStyle(color: theme.textSecondary.withOpacity(0.5)),
                      defaultTextStyle: TextStyle(color: theme.textPrimary),
                      weekendTextStyle: TextStyle(color: theme.textPrimary),
                    ),
                    daysOfWeekStyle: DaysOfWeekStyle(
                      weekdayStyle: TextStyle(color: theme.textSecondary),
                      weekendStyle: TextStyle(color: theme.textSecondary),
                    ),
                    eventLoader: (day) {
                      final dateKey = day.toIso8601String().split('T')[0];
                      return meals[dateKey] ?? [];
                    },
                    onDaySelected: (selectedDay, focusedDay) {
                      final dateKey = selectedDay.toIso8601String().split('T')[0];
                      if (calendarDaysWithRecipes.contains(dateKey)) {
                        final dayMeals = meals[dateKey] ?? [];
                        if (dayMeals.isNotEmpty) {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (context) => DraggableScrollableSheet(
                              initialChildSize: 0.7,
                              minChildSize: 0.5,
                              maxChildSize: 0.9,
                              expand: true,
                              builder: (context, scrollController) => _DayRecipesSheet(
                                day: selectedDay,
                                meals: dayMeals,
                                theme: theme,
                                isLoading: isLoading,
                                onRecipeTap: onRecipeTap,
                              ),
                            ),
                          );
                        }
                      }
                    },
                    calendarBuilders: CalendarBuilders(
                      markerBuilder: (context, day, events) {
                        if (events.isNotEmpty) {
                          return Positioned(
                            right: 1,
                            bottom: 1,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: theme.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                          );
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [theme.error, theme.warning]),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ElevatedButton(
                        onPressed: isLoading
                            ? null
                            : () => showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: theme.surface,
                            title: Text('Xác nhận xóa', style: TextStyle(color: theme.textPrimary)),
                            content: Text(
                              'Bạn có chắc chắn muốn xóa toàn bộ lịch bữa ăn?',
                              style: TextStyle(color: theme.textSecondary),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: Text('Hủy', style: TextStyle(color: theme.secondary)),
                              ),
                              TextButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  onDeleteDay(DateTime.now());
                                },
                                child: Text('Xóa', style: TextStyle(color: theme.error)),
                              ),
                            ],
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(
                          isLoading ? 'Đang xóa...' : 'Xóa toàn bộ lịch',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderSection extends StatelessWidget {
  final ThemeColors theme;
  final bool isLoading;
  final String selectedTimeFrame;
  final String? selectedDiet;
  final int targetCalories;
  final bool showAdvancedOptions;
  final bool useFridgeIngredients;
  final String? selectedFridgeId;
  final List<Map<String, dynamic>> userFridges;
  final Map<String, String> timeFrameTranslations;
  final List<String> diets;
  final Function(String?) onTimeFrameChanged;
  final Function(String?) onDietChanged;
  final Function(String) onCaloriesChanged;
  final VoidCallback onToggleAdvancedOptions;
  final Function(bool?) onUseFridgeChanged;
  final Function(String?) onFridgeChanged;
  final VoidCallback onGeneratePlan;
  final VoidCallback onAddAllToCalendar;
  final VoidCallback onDeleteAllCalendar;
  final DateTime focusedDay;
  final DateTime selectedDay;
  final Set<String> calendarDaysWithRecipes;
  final Function(DateTime, DateTime) onDaySelected;

  const _HeaderSection({
    required this.theme,
    required this.isLoading,
    required this.selectedTimeFrame,
    required this.selectedDiet,
    required this.targetCalories,
    required this.showAdvancedOptions,
    required this.useFridgeIngredients,
    required this.selectedFridgeId,
    required this.userFridges,
    required this.timeFrameTranslations,
    required this.diets,
    required this.onTimeFrameChanged,
    required this.onDietChanged,
    required this.onCaloriesChanged,
    required this.onToggleAdvancedOptions,
    required this.onUseFridgeChanged,
    required this.onFridgeChanged,
    required this.onGeneratePlan,
    required this.onAddAllToCalendar,
    required this.onDeleteAllCalendar,
    required this.focusedDay,
    required this.selectedDay,
    required this.calendarDaysWithRecipes,
    required this.onDaySelected,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final fontSize = screenWidth < 400 ? 13.0 : 15.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(theme.isDarkMode ? 77 : 13),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TableCalendar(
            firstDay: DateTime.now().subtract(const Duration(days: 7)),
            lastDay: DateTime.now().add(const Duration(days: 7)),
            focusedDay: focusedDay,
            selectedDayPredicate: (day) => isSameDay(day, selectedDay),
            locale: 'vi_VN',
            calendarFormat: CalendarFormat.week,
            headerStyle: HeaderStyle(
              formatButtonVisible: false,
              titleTextStyle: TextStyle(color: theme.textPrimary, fontSize: fontSize),
            ),
            calendarStyle: CalendarStyle(
              todayDecoration: BoxDecoration(
                color: theme.primary.withOpacity(0.3),
                shape: BoxShape.circle,
              ),
              selectedDecoration: BoxDecoration(
                color: theme.primary,
                shape: BoxShape.circle,
              ),
              markerDecoration: BoxDecoration(
                color: theme.accent,
                shape: BoxShape.circle,
              ),
              outsideTextStyle: TextStyle(color: theme.textSecondary.withOpacity(0.5)),
              defaultTextStyle: TextStyle(color: theme.textPrimary),
              weekendTextStyle: TextStyle(color: theme.textPrimary),
            ),
            daysOfWeekStyle: DaysOfWeekStyle(
              weekdayStyle: TextStyle(color: theme.textSecondary),
              weekendStyle: TextStyle(color: theme.textSecondary),
            ),
            eventLoader: (day) {
              final dateKey = day.toIso8601String().split('T')[0];
              return calendarDaysWithRecipes.contains(dateKey) ? [{}] : [];
            },
            onDaySelected: onDaySelected,
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, day, events) {
                if (events.isNotEmpty) {
                  return Positioned(
                    right: 1,
                    bottom: 1,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: theme.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  );
                }
                return null;
              },
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: selectedTimeFrame,
                  decoration: InputDecoration(
                    labelText: 'Khung thời gian',
                    labelStyle: TextStyle(color: theme.textSecondary),
                    filled: true,
                    fillColor: theme.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: theme.secondary),
                    ),
                  ),
                  items: timeFrameTranslations.entries
                      .map((entry) => DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      entry.value,
                      style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                    ),
                  ))
                      .toList(),
                  onChanged: isLoading ? null : onTimeFrameChanged,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: selectedDiet,
                  decoration: InputDecoration(
                    labelText: 'Chế độ ăn',
                    labelStyle: TextStyle(color: theme.textSecondary),
                    filled: true,
                    fillColor: theme.background,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: theme.secondary),
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Không chọn')),
                    ...diets.map((diet) => DropdownMenuItem(
                      value: diet,
                      child: Text(
                        diet == 'Vegetarian'
                            ? 'Ăn chay'
                            : diet == 'Vegan'
                            ? 'Thuần chay'
                            : diet == 'Gluten Free'
                            ? 'Không gluten'
                            : diet == 'Ketogenic'
                            ? 'Keto'
                            : 'Ăn cá',
                        style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                      ),
                    )),
                  ],
                  onChanged: isLoading ? null : onDietChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: targetCalories.toString(),
            decoration: InputDecoration(
              labelText: 'Mục tiêu Calo',
              labelStyle: TextStyle(color: theme.textSecondary),
              filled: true,
              fillColor: theme.background,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: theme.secondary),
              ),
              suffixText: 'kcal',
            ),
            keyboardType: TextInputType.number,
            onChanged: onCaloriesChanged,
            enabled: !isLoading,
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onToggleAdvancedOptions,
            icon: Icon(
              showAdvancedOptions ? Icons.expand_less : Icons.expand_more,
              color: theme.primary,
            ),
            label: Text(
              showAdvancedOptions ? 'Ẩn tùy chọn nâng cao' : 'Hiển thị tùy chọn nâng cao',
              style: TextStyle(color: theme.primary, fontSize: fontSize),
            ),
          ),
          if (showAdvancedOptions) ...[
            CheckboxListTile(
              title: Text(
                'Sử dụng nguyên liệu từ tủ lạnh',
                style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
              ),
              value: useFridgeIngredients,
              onChanged: isLoading ? null : onUseFridgeChanged,
              activeColor: theme.primary,
              checkColor: Colors.white,
            ),
            if (useFridgeIngredients && userFridges.isNotEmpty)
              DropdownButtonFormField<String>(
                value: selectedFridgeId,
                decoration: InputDecoration(
                  labelText: 'Chọn tủ lạnh',
                  labelStyle: TextStyle(color: theme.textSecondary),
                  filled: true,
                  fillColor: theme.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: theme.secondary),
                  ),
                ),
                items: userFridges
                    .map<DropdownMenuItem<String>>((fridge) => DropdownMenuItem<String>(
                  value: fridge['fridgeId'] as String,
                  child: Text(
                    fridge['name'] as String,
                    style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                  ),
                ))
                    .toList(),
                onChanged: isLoading ? null : onFridgeChanged,
              ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [theme.primary, theme.accent]),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ElevatedButton(
                    onPressed: isLoading ? null : onGeneratePlan,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(
                      isLoading ? 'Đang tạo...' : 'Tạo kế hoạch',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [theme.accent, theme.primary]),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ElevatedButton(
                    onPressed: isLoading ? null : onAddAllToCalendar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(
                      isLoading ? 'Đang thêm...' : 'Thêm tất cả vào lịch',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [theme.error, theme.warning]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ElevatedButton(
              onPressed: isLoading ? null : onDeleteAllCalendar,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                isLoading ? 'Đang xóa...' : 'Xóa toàn bộ lịch',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
class _ShimmerList extends StatelessWidget {
  final ThemeColors theme;

  const _ShimmerList({required this.theme});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: 5,
      itemBuilder: (context, index) => Shimmer.fromColors(
        baseColor: theme.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
        highlightColor: theme.isDarkMode ? Colors.grey[600]! : Colors.grey[200]!,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: theme.surface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            title: Container(
              height: 16,
              width: double.infinity,
              color: Colors.white,
            ),
            subtitle: Container(
              height: 12,
              width: 100,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ThemeColors theme;
  final bool showCalendarButton;
  final VoidCallback onShowCalendar;

  const _EmptyState({
    required this.theme,
    required this.showCalendarButton,
    required this.onShowCalendar,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.restaurant_menu,
            size: 48,
            color: theme.textSecondary,
          ),
          const SizedBox(height: 12),
          Text(
            'Chưa có kế hoạch bữa ăn',
            style: TextStyle(
              fontSize: 16,
              color: theme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tạo kế hoạch mới hoặc xem lịch!',
            style: TextStyle(
              fontSize: 14,
              color: theme.textSecondary,
            ),
          ),
          if (showCalendarButton) ...[
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: onShowCalendar,
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.primary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text(
                'Xem lịch',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FooterActions extends StatelessWidget {
  final ThemeColors theme;
  final bool isLoading;
  final VoidCallback onAddToCalendar;
  final VoidCallback onRemoveFromCalendar;

  const _FooterActions({
    required this.theme,
    required this.isLoading,
    required this.onAddToCalendar,
    required this.onRemoveFromCalendar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(theme.isDarkMode ? 77 : 13),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [theme.primary, theme.accent]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ElevatedButton(
                onPressed: isLoading ? null : onAddToCalendar,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(
                  isLoading ? 'Đang thêm...' : 'Thêm vào lịch',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [theme.error, theme.warning]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ElevatedButton(
                onPressed: isLoading ? null : onRemoveFromCalendar,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(
                  isLoading ? 'Đang xóa...' : 'Xóa khỏi lịch',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayRecipesSheet extends StatelessWidget {
  final DateTime day;
  final List<Map<String, dynamic>> meals;
  final ThemeColors theme;
  final bool isLoading;
  final Function(Map<String, dynamic>) onRecipeTap;

  const _DayRecipesSheet({
    required this.day,
    required this.meals,
    required this.theme,
    required this.isLoading,
    required this.onRecipeTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: theme.isDarkMode ? Colors.grey[400]! : Colors.grey[300]!,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Bữa ăn ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)}',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: theme.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: meals.length,
              itemBuilder: (context, index) {
                final recipe = meals[index];
                return ListTile(
                  leading: _RecipeImage(imageUrl: recipe['image']?.toString(), theme: theme),
                  title: Text(
                    recipe['title']?.toString() ?? 'Không có tiêu đề',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    recipe['timeSlot'] != null
                        ? {'morning': 'Sáng', 'afternoon': 'Trưa', 'evening': 'Tối'}[recipe['timeSlot']] ?? 'Khác'
                        : 'Không xác định',
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  onTap: () => onRecipeTap(recipe),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}