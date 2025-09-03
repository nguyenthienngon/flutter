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

  // Define exact hex colors for consistency
  static const Color _primaryLight = Color(0xFF0078D7);
  static const Color _secondaryLight = Color(0xFF50E3C2);
  static const Color _accentLight = Color(0xFF00B294);
  static const Color _successLight = Color(0xFF00C851);
  static const Color _warningLight = Color(0xFFE67E22);
  static const Color _errorLight = Color(0xFFE74C3C);
  static const Color _backgroundLight = Color(0xFFE6F7FF);
  static const Color _surfaceLight = Colors.white;
  static const Color _textPrimaryLight = Color(0xFF202124);
  static const Color _textSecondaryLight = Color(0xFF5F6368);

  static const Color _primaryDark = Color(0xFF0078D7);
  static const Color _secondaryDark = Color(0xFF50E3C2);
  static const Color _accentDark = Color(0xFF00B294);
  static const Color _successDark = Color(0xFF00C851);
  static const Color _warningDark = Color(0xFFE67E22);
  static const Color _errorDark = Color(0xFFE74C3C);
  static const Color _backgroundDark = Color(0xFF121212);
  static const Color _surfaceDark = Color(0xFF1E1E1E);
  static const Color _textPrimaryDark = Color(0xFFE0E0E0);
  static const Color _textSecondaryDark = Color(0xFFB0B0B0);

  Color get primary => isDarkMode ? _primaryDark : _primaryLight;
  Color get accent => isDarkMode ? _accentDark : _accentLight;
  Color get secondary => isDarkMode ? _secondaryDark : _secondaryLight;
  Color get error => isDarkMode ? _errorDark : _errorLight;
  Color get warning => isDarkMode ? _warningDark : _warningLight;
  Color get success => isDarkMode ? _successDark : _successLight;
  Color get background => isDarkMode ? _backgroundDark : _backgroundLight;
  Color get surface => isDarkMode ? _surfaceDark : _surfaceLight;
  Color get textPrimary => isDarkMode ? _textPrimaryDark : _textPrimaryLight;
  Color get textSecondary => isDarkMode ? _textSecondaryDark : _textSecondaryLight;
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
  bool _showCalendar = true;
  String? _errorMessage;
  String? _selectedDiet;
  String _selectedTimeFrame = 'week';
  int _targetCalories = 2000;
  bool _useFridgeIngredients = false;
  DateTime _selectedDay = DateTime.now();
  DateTime _focusedDay = DateTime.now();
  List<String> _sortedDays = [];

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
            if (date.isEmpty) continue;

            mealsByDate[date] = List<Map<String, dynamic>>.from(meal['meals'] ?? []);
            daysWithRecipes.add(date);
            _addedToCalendar[date] = true;
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
        await _addMealToSpecificDate(dateStr, recipe);
      },
      errorMessage: 'Không thể thêm vào lịch.',
    );
  }

  Future<void> _addMealToSpecificDate(String dateStr, Map<String, dynamic> recipe) async {
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
  }

  Future<void> _addDayToCalendar(DateTime date) async {
    final dateKey = date.toIso8601String().split('T')[0];
    if (_dayLoading[dateKey] == true) return;

    await _executeWithLoading(
          () async {
        var mealsForDay = _allCalendarMeals[dateKey] ?? [];
        if (mealsForDay.isEmpty) {
          mealsForDay = _mealPlan['week']?[dateKey] ?? [];
          final payload = {
            'userId': widget.userId,
            'date': dateKey,
            'meals': mealsForDay,
          };

          final response = await _httpClient.post(
            Uri.parse('$_ngrokUrl/add_to_calendar'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          );

          if (response.statusCode == 200) {
            if (mounted) {
              setState(() {
                _allCalendarMeals[dateKey] = mealsForDay;
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
    if (_isLoading || (_mealPlan['week']?.isEmpty ?? true)) {
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
        var mealsForDay = _allCalendarMeals[dateKey] ?? [];
        if (mealsForDay.isEmpty && _calendarDaysWithRecipes.contains(dateKey)) {
          final response = await _httpClient.get(
            Uri.parse('$_ngrokUrl/get_calendar_meals?userId=${widget.userId}&date=$dateKey'),
            headers: {'Content-Type': 'application/json'},
          );

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            mealsForDay = List<Map<String, dynamic>>.from(data['meals'] ?? []);
          } else {
            throw Exception('Không thể tải công thức lịch: ${response.body}');
          }
        }

        for (var meal in mealsForDay) {
          final recipeId = meal['id']?.toString() ?? '';
          if (recipeId.isNotEmpty) {
            final deleteResponse = await _httpClient.delete(
              Uri.parse('$_ngrokUrl/delete_meal_from_calendar?userId=${widget.userId}&date=$dateKey&recipeId=$recipeId'),
              headers: {'Content-Type': 'application/json'},
            );

            if (deleteResponse.statusCode != 200) {
              throw Exception('Không thể xóa bữa ăn $recipeId: ${deleteResponse.body}');
            }
          }
        }

        if (mounted) {
          setState(() {
            _calendarDaysWithRecipes.remove(dateKey);
            _allCalendarMeals.remove(dateKey);
            _addedToCalendar[dateKey] = false;
          });
        }
        _showSnackBar('Đã xóa ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)} khỏi lịch!', _theme.success);
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
          final seenTitles = <String>{}; // Theo dõi các tiêu đề công thức đã xuất hiện
          final uniqueRecipeIds = <String>[]; // Cập nhật danh sách ID công thức duy nhất

          for (var day in mealPlanData) {
            final date = day['day'] as String? ?? '';
            if (date.isEmpty) continue;

            final meals = day['meals'] as Map<String, dynamic>? ?? {};
            processedWeek[date] = [];
            _addedToCalendar[date] = false;

            for (var timeSlot in ['morning', 'afternoon', 'evening']) {
              final recipes = List<dynamic>.from(meals[timeSlot] ?? []);
              for (var recipe in recipes) {
                final recipeTitle = recipe['title']?.toString() ?? 'Không có tiêu đề';
                if (seenTitles.contains(recipeTitle)) continue; // Bỏ qua nếu tiêu đề đã xuất hiện
                seenTitles.add(recipeTitle); // Thêm tiêu đề vào danh sách đã thấy

                final recipeId = recipe['id']?.toString() ?? 'fallback_${DateTime.now().millisecondsSinceEpoch}';
                uniqueRecipeIds.add(recipeId);
                processedWeek[date]!.add({
                  'id': recipeId,
                  'title': recipeTitle,
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
              _seenRecipeIds['week'] = uniqueRecipeIds;
              _sortedDays = processedWeek.keys.toList()..sort();

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
          // For DELETE request, send userId as a query parameter
          final response = await _httpClient.delete(
            Uri.parse('$_ngrokUrl/delete_favorite_recipe/$recipeId?userId=${widget.userId}'),
            headers: {'Content-Type': 'application/json'},
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
          // For POST request, keep the existing logic as it is correct
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
        })).toList() ??
            [];

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

    // Sort meals by time slot
    final timeSlotOrder = {
      'morning': 0,
      'afternoon': 1,
      'evening': 2,
    };
    meals.sort((a, b) {
      return (timeSlotOrder[a['timeSlot']] ?? 3).compareTo(timeSlotOrder[b['timeSlot']] ?? 3);
    });

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
            onDeleteMeal: _deleteCalendarMeal,
            onMoveMeal: (String oldDate, String recipeId, Map<String, dynamic> recipe) async {
              final newDate = await _selectCalendarDate();
              if (newDate != null) {
                final newDateKey = newDate.toIso8601String().split('T')[0];
                await _deleteCalendarMeal(oldDate, recipeId);
                await _addMealToSpecificDate(newDateKey, recipe);
              }
            },
          ),
        ),
      );
    }
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
          setState(() {
            _mealPlan['week']?[dateKey]?.removeWhere((meal) => meal['id'].toString() == recipeId);
            _seenRecipeIds['week']?.remove(recipeId);
            if (_mealPlan['week']?[dateKey]?.isEmpty ?? true) {
              _mealPlan['week']?.remove(dateKey);
              _sortedDays.remove(dateKey);
            }
          });
          _showSnackBar('Đã xóa "${recipe['title'] ?? 'Không có tiêu đề'}" khỏi kế hoạch!', _theme.success);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _theme.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(_theme.isDarkMode ? 77 : 13),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: _RecipeImage(imageUrl: recipe['image']?.toString(), theme: _theme),
          title: Text(
            recipe['title']?.toString() ?? 'Không có tiêu đề',
            style: TextStyle(
              color: _theme.textPrimary,
              fontSize: 16,
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
              fontSize: 14,
            ),
          ),
          trailing: IconButton(
            icon: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              color: isFavorite ? _theme.error : _theme.textSecondary,
              size: 24,
            ),
            onPressed: _isLoading ? null : () => _toggleFavorite(recipeId, isFavorite),
          ),
          onTap: () => _showRecipeDetails(recipe),
        ),
      ),
    );
  }

  Widget _buildIngredientsSection(String title, List<String> items, [Color? color, IconData? icon]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon ?? Icons.check_circle, color: color ?? _theme.primary, size: 20),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: _getFontSize(context, 18),
                fontWeight: FontWeight.bold,
                color: _theme.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _theme.surface,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(_theme.isDarkMode ? 77 : 13),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Text(
              'Không có nguyên liệu',
              style: TextStyle(color: _theme.textSecondary, fontSize: _getFontSize(context, 14)),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (context, index) => Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: (color ?? _theme.primary).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: (color ?? _theme.primary).withOpacity(0.3)),
                boxShadow: [
                  BoxShadow(
                    color: (color ?? _theme.primary).withOpacity(0.05),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Icon(Icons.circle, color: color ?? _theme.primary, size: 12),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      items[index],
                      style: TextStyle(color: _theme.textPrimary, fontSize: _getFontSize(context, 15)),
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
        .where((n) => n is Map<String, dynamic> && keyNutrients.contains(n['name']) && n['amount'] is num && n['amount'] > 0 && n['unit'] is String)
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
        style: TextStyle(fontSize: _getFontSize(context, 14), color: _theme.textSecondary),
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
            fontSize: _getFontSize(context, 18),
            fontWeight: FontWeight.bold,
            color: _theme.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: chartHeight,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _theme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _theme.secondary.withOpacity(0.3), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(_theme.isDarkMode ? 77 : 13),
                blurRadius: 10,
                offset: const Offset(0, 4),
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
                        color: _theme.background.withOpacity(0.5),
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
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            label == 'Calories'
                                ? 'Calo'
                                : label == 'Fat'
                                ? 'Chất béo'
                                : label == 'Carbs'
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
                border: Border.all(color: _theme.secondary.withOpacity(0.3), width: 1),
              ),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (value) => FlLine(
                  color: _theme.secondary.withOpacity(0.2),
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
        const SizedBox(height: 12),
        ...filteredNutrients.map((nutrient) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
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
                style: TextStyle(fontSize: _getFontSize(context, 15), color: _theme.textPrimary),
              ),
              Text(
                '${(nutrient['amount'] as num).toStringAsFixed(1)} ${nutrient['unit']}',
                style: TextStyle(fontSize: _getFontSize(context, 15), color: _theme.textPrimary, fontWeight: FontWeight.w600),
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

  void _toggleCalendar() {
    setState(() {
      _showCalendar = !_showCalendar;
      if (_showCalendar) {
        _showCalendarSheet();
      }
    });
  }

  void _showCalendarSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: true,
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
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _showCalendar = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final meals = _mealPlan['week'] ?? {};
    final DateTime now = DateTime.now();
    final DateTime firstDay = now.subtract(const Duration(days: 30)); // 1-month range
    final DateTime lastDay = now.add(const Duration(days: 30));

    return Scaffold(
      backgroundColor: _theme.background,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              // Modern Header
              SlideTransition(
                position: _headerSlideAnimation,
                child: Container(
                  margin: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [_theme.primary, _theme.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: _theme.primary.withOpacity(0.4),
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
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      gradient: RadialGradient(
                                        colors: [_theme.secondary, Colors.white.withOpacity(0.3)],
                                        radius: 0.8,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    'Kế hoạch bữa ăn',
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: IconButton(
                                icon: Icon(
                                  _showCalendar ? Icons.calendar_today : Icons.calendar_today_outlined,
                                  color: Colors.white,
                                ),
                                onPressed: _toggleCalendar,
                                tooltip: _showCalendar ? 'Ẩn lịch' : 'Hiện lịch',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              FadeTransition(
                opacity: _fadeAnimation,
                child: Column(
                  children: [
                    // Small Weekly Calendar at the top
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: _theme.surface,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withAlpha(_theme.isDarkMode ? 77 : 13),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: TableCalendar(
                        firstDay: firstDay,
                        lastDay: lastDay,
                        focusedDay: _focusedDay,
                        locale: 'vi_VN',
                        calendarFormat: CalendarFormat.week,
                        headerVisible: false,
                        rowHeight: 60,
                        daysOfWeekHeight: 30,
                        headerStyle: HeaderStyle(
                          formatButtonVisible: false,
                          titleCentered: true,
                          titleTextStyle: TextStyle(
                            color: _theme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          leftChevronIcon: Icon(Icons.chevron_left, color: _theme.primary),
                          rightChevronIcon: Icon(Icons.chevron_right, color: _theme.primary),
                        ),
                        calendarStyle: CalendarStyle(
                          todayDecoration: BoxDecoration(
                            color: _theme.primary.withOpacity(0.3),
                            shape: BoxShape.circle,
                          ),
                          selectedDecoration: BoxDecoration(
                            color: _theme.primary,
                            shape: BoxShape.circle,
                          ),
                          markerDecoration: BoxDecoration(
                            color: _theme.accent,
                            shape: BoxShape.circle,
                          ),
                          outsideTextStyle: TextStyle(color: _theme.textSecondary.withOpacity(0.5)),
                          defaultTextStyle: TextStyle(color: _theme.textPrimary),
                          weekendTextStyle: TextStyle(color: _theme.textPrimary),
                          holidayTextStyle: TextStyle(color: _theme.error),
                        ),
                        daysOfWeekStyle: DaysOfWeekStyle(
                          weekdayStyle: TextStyle(color: _theme.textSecondary),
                          weekendStyle: TextStyle(color: _theme.textSecondary),
                        ),
                        eventLoader: (day) {
                          final dateKey = day.toIso8601String().split('T')[0];
                          return _allCalendarMeals[dateKey] ?? [];
                        },
                        onDaySelected: (selectedDay, focusedDay) {
                          setState(() {
                            _focusedDay = focusedDay;
                          });
                          final dateKey = selectedDay.toIso8601String().split('T')[0];
                          if (_calendarDaysWithRecipes.contains(dateKey)) {
                            _showRecipesForDay(selectedDay);
                          }
                        },
                        calendarBuilders: CalendarBuilders(
                          markerBuilder: (context, day, events) {
                            if (events.isNotEmpty) {
                              return Positioned(
                                right: 1,
                                bottom: 1,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _theme.accent,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              );
                            }
                            return null;
                          },
                        ),
                      ),
                    ),
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
                    _isLoading
                        ? _ShimmerList(theme: _theme)
                        : meals.isEmpty
                        ? _EmptyState(
                      theme: _theme,
                      showCalendarButton: _calendarDaysWithRecipes.isNotEmpty,
                      onShowCalendar: _toggleCalendar,
                    )
                        : SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6, // Giới hạn chiều cao
                      child: CustomScrollView(
                        shrinkWrap: true,
                        physics: const ClampingScrollPhysics(),
                        slivers: [
                          for (String dateKey in _sortedDays)
                            ...[
                              SliverPersistentHeader(
                                pinned: false,
                                floating: true,
                                delegate: _DayHeaderDelegate(
                                  dateKey: dateKey,
                                  theme: _theme,
                                  mealsCount: meals[dateKey]?.length ?? 0,
                                  isLoading: _dayLoading[dateKey] ?? false,
                                  onAddDay: () => _addDayToCalendar(DateTime.parse(dateKey)),
                                ),
                              ),
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                    final dayMeals = meals[dateKey] ?? [];
                                    if (index >= dayMeals.length) return null;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      child: _buildRecipeTile(dayMeals[index]),
                                    );
                                  },
                                  childCount: meals[dateKey]?.length ?? 0,
                                ),
                              ),
                            ],
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
    );
  }
}

class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String dateKey;
  final ThemeColors theme;
  final int mealsCount;
  final bool isLoading;
  final VoidCallback onAddDay;

  _DayHeaderDelegate({
    required this.dateKey,
    required this.theme,
    required this.mealsCount,
    required this.isLoading,
    required this.onAddDay,
  });

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final date = DateTime.parse(dateKey);
    final dayName = DateFormat('EEEE', 'vi_VN').format(date);
    final dayDate = DateFormat('d/M/yyyy', 'vi_VN').format(date);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [theme.primary.withOpacity(0.9), theme.accent.withOpacity(0.9)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    dayName.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    dayDate,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.9),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$mealsCount công thức',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: IconButton(
                icon: isLoading
                    ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
                    : const Icon(Icons.add, color: Colors.white, size: 20),
                onPressed: isLoading ? null : onAddDay,
                tooltip: 'Thêm tất cả vào lịch',
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  double get maxExtent => 80.0;

  @override
  double get minExtent => 80.0;

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) => true;
}

class _RecipeImage extends StatelessWidget {
  final String? imageUrl;
  final ThemeColors theme;

  const _RecipeImage({required this.imageUrl, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: theme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(theme.isDarkMode ? 77 : 13),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: imageUrl?.isNotEmpty ?? false
          ? ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.network(
          imageUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => Icon(
            Icons.restaurant,
            color: theme.primary,
            size: 30,
          ),
        ),
      )
          : Icon(
        Icons.restaurant,
        color: theme.primary,
        size: 30,
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
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(theme.isDarkMode ? 0.3 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: DefaultTabController(
        length: 4,
        child: Column(
          children: [
            Container(
              width: 50,
              height: 5,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: theme.textSecondary.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2.5),
              ),
            ),
            TabBar(
              labelColor: theme.primary,
              unselectedLabelColor: theme.textSecondary,
              indicatorColor: theme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              labelPadding: const EdgeInsets.symmetric(horizontal: 4),
              tabs: [
                Tab(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.info_outline, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Tổng quan',
                          style: TextStyle(fontSize: getFontSize(14), overflow: TextOverflow.ellipsis),
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
                      const Icon(Icons.local_dining, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Nguyên liệu',
                          style: TextStyle(fontSize: getFontSize(14), overflow: TextOverflow.ellipsis),
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
                      const Icon(Icons.book, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Hướng dẫn',
                          style: TextStyle(fontSize: getFontSize(14), overflow: TextOverflow.ellipsis),
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
                      const Icon(Icons.calendar_today, size: 18),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Lịch',
                          style: TextStyle(fontSize: getFontSize(14), overflow: TextOverflow.ellipsis),
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
                  ? Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(theme.primary)))
                  : TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
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
                                  fontSize: getFontSize(24),
                                  fontWeight: FontWeight.bold,
                                  color: theme.textPrimary,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              icon: isLoading
                                  ? SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(theme.primary)),
                              )
                                  : Icon(
                                recipe['isFavorite'] == true ? Icons.favorite : Icons.favorite_border,
                                color: recipe['isFavorite'] == true ? theme.error : theme.textSecondary,
                                size: 28,
                              ),
                              onPressed: isLoading ? null : onToggleFavorite,
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Hero(
                          tag: 'recipe_image_${recipe['id']}',
                          child: recipe['image'].toString().isNotEmpty
                              ? Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(theme.isDarkMode ? 0.2 : 0.1),
                                  blurRadius: 10,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: Image.network(
                                recipe['image'].toString(),
                                height: 200,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                loadingBuilder: (context, child, loadingProgress) {
                                  if (loadingProgress == null) return child;
                                  return SizedBox(
                                    height: 200,
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        value: loadingProgress.expectedTotalBytes != null
                                            ? loadingProgress.cumulativeBytesLoaded / (loadingProgress.expectedTotalBytes ?? 1)
                                            : null,
                                        valueColor: AlwaysStoppedAnimation<Color>(theme.primary),
                                      ),
                                    ),
                                  );
                                },
                                errorBuilder: (context, error, stackTrace) => Container(
                                  height: 200,
                                  decoration: BoxDecoration(
                                    color: theme.surface,
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Icon(
                                    Icons.broken_image,
                                    size: 48,
                                    color: theme.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          )
                              : Container(
                            height: 200,
                            decoration: BoxDecoration(
                              color: theme.surface,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(theme.isDarkMode ? 0.2 : 0.1),
                                  blurRadius: 10,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Icon(
                                Icons.restaurant,
                                size: 48,
                                color: theme.textSecondary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [theme.primary.withOpacity(0.1), theme.accent.withOpacity(0.1)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: theme.primary.withOpacity(0.05),
                                blurRadius: 8,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.access_time, color: theme.primary, size: 20),
                              const SizedBox(width: 12),
                              Text(
                                'Thời gian chuẩn bị: ${recipe['readyInMinutes'].toString()} phút',
                                style: TextStyle(
                                  fontSize: getFontSize(16),
                                  fontWeight: FontWeight.w600,
                                  color: theme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        recipe['nutrition']?.isNotEmpty ?? false
                            ? buildNutritionSection(recipe['nutrition'])
                            : Text(
                          'Không có thông tin dinh dưỡng',
                          style: TextStyle(fontSize: getFontSize(14), color: theme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        buildIngredientsSection('Nguyên liệu cần thiết', requiredIngredients, theme.primary, Icons.local_dining),
                        const SizedBox(height: 20),
                        if (recipe['ingredientsMissing']?.isNotEmpty ?? false)
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [theme.accent, theme.primary],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: theme.accent.withOpacity(0.3),
                                  blurRadius: 12,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: isLoading ? null : onAddToShoppingList,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.add_shopping_cart, color: Colors.white, size: 20),
                                  const SizedBox(width: 12),
                                  Text(
                                    isLoading ? 'Đang thêm...' : 'Thêm vào danh sách mua sắm',
                                    style: TextStyle(
                                      fontSize: getFontSize(16),
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
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Hướng dẫn',
                          style: TextStyle(
                            fontSize: getFontSize(18),
                            fontWeight: FontWeight.bold,
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: theme.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: theme.secondary.withOpacity(0.3)),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withAlpha(theme.isDarkMode ? 77 : 13),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Text(
                            recipe['instructions'].toString(),
                            style: TextStyle(
                              fontSize: getFontSize(15),
                              color: theme.textPrimary,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Quản lý lịch',
                          style: TextStyle(
                            fontSize: getFontSize(18),
                            fontWeight: FontWeight.bold,
                            color: theme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [theme.primary, theme.accent],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: theme.primary.withOpacity(0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ElevatedButton.icon(
                            onPressed: isLoading ? null : onAddToCalendar,
                            icon: isLoading
                                ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                                : const Icon(Icons.calendar_today, color: Colors.white, size: 20),
                            label: Text(
                              isLoading ? 'Đang thêm...' : 'Thêm vào lịch',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: getFontSize(16),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [theme.error, theme.warning],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: theme.error.withOpacity(0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: ElevatedButton(
                            onPressed: isLoading ? null : onRemoveFromCalendar,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            child: Text(
                              isLoading ? 'Đang xóa...' : 'Xóa khỏi lịch',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: getFontSize(16),
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
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(theme.isDarkMode ? 0.3 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 50,
            height: 5,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: theme.textSecondary.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(
              'Lịch bữa ăn',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: theme.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: isLoading
                ? Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(theme.primary)))
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
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      leftChevronIcon: Icon(Icons.chevron_left, color: theme.primary),
                      rightChevronIcon: Icon(Icons.chevron_right, color: theme.primary),
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
                      holidayTextStyle: TextStyle(color: theme.error),
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
                                onDeleteMeal: onDeleteMeal, // Pass the onDeleteMeal function
                                onMoveMeal: (oldDate, recipeId, recipe) {
                                  // Implement move meal logic, possibly calling a method from parent
                                  // For now, we'll just call onDeleteMeal to remove from current date
                                  onDeleteMeal(oldDate, recipeId);
                                  // You may want to add logic to add the meal to a new date
                                },
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
                              width: 8,
                              height: 8,
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
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [theme.error, theme.warning],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: theme.error.withOpacity(0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
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
                              ElevatedButton(
                                onPressed: () {
                                  Navigator.pop(context);
                                  onDeleteDay(DateTime.now()); // This will trigger deleteAllCalendarMeals
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: theme.error,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                child: Text('Xóa', style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: Text(
                          isLoading ? 'Đang xóa...' : 'Xóa toàn bộ lịch',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
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
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final fontSize = screenWidth < 360 ? 12.0 : screenWidth < 400 ? 13.0 : 14.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.background.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: theme.secondary.withOpacity(0.2)),
                  ),
                  child: DropdownButtonFormField<String>(
                    value: selectedTimeFrame,
                    decoration: InputDecoration(
                      labelText: 'Khung thời gian',
                      labelStyle: TextStyle(color: theme.textSecondary, fontWeight: FontWeight.w500, fontSize: fontSize),
                      filled: true,
                      fillColor: Colors.transparent,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                    dropdownColor: theme.surface,
                    style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                    icon: Icon(Icons.arrow_drop_down, color: theme.textSecondary, size: fontSize + 4),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: onToggleAdvancedOptions,
            icon: Icon(
              showAdvancedOptions ? Icons.expand_less : Icons.expand_more,
              color: theme.primary,
              size: fontSize + 4,
            ),
            label: Text(
              showAdvancedOptions ? 'Ẩn tùy chọn nâng cao' : 'Hiển thị tùy chọn nâng cao',
              style: TextStyle(color: theme.primary, fontSize: fontSize + 1, fontWeight: FontWeight.w600),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: showAdvancedOptions
                ? Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: theme.background.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: theme.secondary.withOpacity(0.2)),
                        ),
                        child: DropdownButtonFormField<String>(
                          value: selectedDiet,
                          decoration: InputDecoration(
                            labelText: 'Chế độ ăn',
                            labelStyle: TextStyle(color: theme.textSecondary, fontWeight: FontWeight.w500, fontSize: fontSize),
                            filled: true,
                            fillColor: Colors.transparent,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                          ),
                          items: [
                            DropdownMenuItem(value: null, child: Text('Không chọn', style: TextStyle(color: theme.textPrimary, fontSize: fontSize))),
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
                          dropdownColor: theme.surface,
                          style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                          icon: Icon(Icons.arrow_drop_down, color: theme.textSecondary, size: fontSize + 4),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: theme.background.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: theme.secondary.withOpacity(0.2)),
                  ),
                  child: TextFormField(
                    initialValue: targetCalories.toString(),
                    decoration: InputDecoration(
                      labelText: 'Mục tiêu Calo',
                      labelStyle: TextStyle(color: theme.textSecondary, fontWeight: FontWeight.w500, fontSize: fontSize),
                      filled: true,
                      fillColor: Colors.transparent,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      suffixText: 'kcal',
                      suffixStyle: TextStyle(color: theme.textSecondary, fontSize: fontSize),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: onCaloriesChanged,
                    enabled: !isLoading,
                    style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: theme.background.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: theme.secondary.withOpacity(0.2)),
                  ),
                  child: CheckboxListTile(
                    title: Text(
                      'Sử dụng nguyên liệu từ tủ lạnh',
                      style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                    ),
                    value: useFridgeIngredients,
                    onChanged: isLoading ? null : onUseFridgeChanged,
                    activeColor: theme.primary,
                    checkColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
                const SizedBox(height: 8),
                if (useFridgeIngredients && userFridges.isNotEmpty)
                  Container(
                    decoration: BoxDecoration(
                      color: theme.background.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: theme.secondary.withOpacity(0.2)),
                    ),
                    child: DropdownButtonFormField<String>(
                      value: selectedFridgeId,
                      decoration: InputDecoration(
                        labelText: 'Chọn tủ lạnh',
                        labelStyle: TextStyle(color: theme.textSecondary, fontWeight: FontWeight.w500, fontSize: fontSize),
                        filled: true,
                        fillColor: Colors.transparent,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                      dropdownColor: theme.surface,
                      style: TextStyle(color: theme.textPrimary, fontSize: fontSize),
                      icon: Icon(Icons.arrow_drop_down, color: theme.textSecondary, size: fontSize + 4),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            )
                : const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [theme.primary, theme.accent],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: theme.primary.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: isLoading ? null : onGeneratePlan,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      isLoading ? 'Đang tạo...' : 'Tạo kế hoạch',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize + 1,
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
                    gradient: LinearGradient(
                      colors: [theme.accent, theme.primary],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: theme.accent.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ElevatedButton(
                    onPressed: isLoading ? null : onAddAllToCalendar,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      isLoading ? 'Đang thêm...' : 'Thêm tất cả vào lịch',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize + 1,
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
              gradient: LinearGradient(
                colors: [theme.error, theme.warning],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: theme.error.withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ElevatedButton(
              onPressed: isLoading ? null : onDeleteAllCalendar,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.transparent,
                shadowColor: Colors.transparent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(
                isLoading ? 'Đang xóa...' : 'Xóa toàn bộ lịch',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: fontSize + 1,
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
class _DayRecipesSheet extends StatelessWidget {
  final DateTime day;
  final List<Map<String, dynamic>> meals;
  final ThemeColors theme;
  final bool isLoading;
  final Function(Map<String, dynamic>) onRecipeTap;
  final Function(String, String) onDeleteMeal;
  final Function(String, String, Map<String, dynamic>) onMoveMeal;

  const _DayRecipesSheet({
    required this.day,
    required this.meals,
    required this.theme,
    required this.isLoading,
    required this.onRecipeTap,
    required this.onDeleteMeal,
    required this.onMoveMeal,
  });

  @override
  Widget build(BuildContext context) {
    final dateKey = day.toIso8601String().split('T')[0];
    final dayName = DateFormat('EEEE, d MMMM, yyyy', 'vi_VN').format(day);

    return Container(
      decoration: BoxDecoration(
        color: theme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(theme.isDarkMode ? 0.3 : 0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 50,
            height: 5,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: theme.textSecondary.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2.5),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(
              'Bữa ăn ngày $dayName',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: theme.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: isLoading
                ? Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(theme.primary)))
                : meals.isEmpty
                ? Center(
              child: Text(
                'Không có công thức cho ngày này',
                style: TextStyle(fontSize: 16, color: theme.textSecondary),
              ),
            )
                : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: meals.length,
              itemBuilder: (context, index) {
                final meal = meals[index];
                final recipeId = meal['id']?.toString() ?? '';
                return Dismissible(
                  key: ValueKey('$recipeId-$dateKey-$index'),
                  direction: DismissDirection.horizontal,
                  background: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 16),
                    decoration: BoxDecoration(
                      color: theme.success,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.calendar_today, color: Colors.white),
                  ),
                  secondaryBackground: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 16),
                    decoration: BoxDecoration(
                      color: theme.error,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (direction) async {
                    if (direction == DismissDirection.startToEnd) {
                      // Mở hộp thoại chọn ngày mới
                      final newDate = await showDatePicker(
                        context: context,
                        initialDate: DateTime.now(),
                        firstDate: DateTime.now().subtract(const Duration(days: 1)),
                        lastDate: DateTime.now().add(const Duration(days: 30)),
                        builder: (context, child) => Theme(
                          data: ThemeData(
                            colorScheme: ColorScheme.light(
                              primary: theme.primary,
                              onPrimary: Colors.white,
                              surface: theme.surface,
                              onSurface: theme.textPrimary,
                            ),
                          ),
                          child: child!,
                        ),
                      );

                      if (newDate != null) {
                        final newDateKey = newDate.toIso8601String().split('T')[0];
                        await onMoveMeal(dateKey, recipeId, meal);
                        // Hiển thị thông báo thành công
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Đã di chuyển "${meal['title']}" đến ngày ${DateFormat('d/M/yyyy', 'vi_VN').format(newDate)}'),
                            backgroundColor: theme.success,
                          ),
                        );
                      }
                      return false; // Không xóa widget
                    } else if (direction == DismissDirection.endToStart) {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: theme.surface,
                          title: Text('Xác nhận xóa', style: TextStyle(color: theme.textPrimary)),
                          content: Text(
                            'Xóa "${meal['title'] ?? 'Không có tiêu đề'}" khỏi lịch ngày $dayName?',
                            style: TextStyle(color: theme.textSecondary),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text('Hủy', style: TextStyle(color: theme.secondary)),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text('Xóa', style: TextStyle(color: theme.error)),
                            ),
                          ],
                        ),
                      ) ?? false;

                      if (confirmed) {
                        await onDeleteMeal(dateKey, recipeId);
                        return true;
                      }
                      return false;
                    }
                    return false;
                  },
                  onDismissed: (direction) {
                    // Không cần xử lý trong onDismissed vì đã xử lý trong confirmDismiss
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: theme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(theme.isDarkMode ? 77 : 13),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: _RecipeImage(imageUrl: meal['image']?.toString(), theme: theme),
                      title: Text(
                        meal['title']?.toString() ?? 'Không có tiêu đề',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        meal['timeSlot'] != null
                            ? {'morning': 'Sáng', 'afternoon': 'Trưa', 'evening': 'Tối'}[meal['timeSlot']] ??
                            'Khác'
                            : 'Không xác định',
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      onTap: () => onRecipeTap(meal),
                    ),
                  ),
                );
              },
            ),
          ),


        ],
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
    return Container(
      height: MediaQuery.of(context).size.height * 0.5,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.restaurant_menu,
            size: 80,
            color: theme.textSecondary.withOpacity(0.5),
          ),
          const SizedBox(height: 20),
          Text(
            'Chưa có kế hoạch bữa ăn',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: theme.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          Text(
            'Nhấn "Tạo kế hoạch" để bắt đầu hoặc xem lịch nếu bạn đã thêm món ăn!',
            style: TextStyle(
              fontSize: 14,
              color: theme.textSecondary,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          if (showCalendarButton) ...[
            const SizedBox(height: 20),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [theme.primary, theme.accent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: theme.primary.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: onShowCalendar,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  'Xem lịch',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Shimmer.fromColors(
        baseColor: theme.background.withOpacity(0.5),
        highlightColor: theme.surface.withOpacity(0.8),
        child: ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 5,
          itemBuilder: (context, index) => Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 80,
            decoration: BoxDecoration(
              color: theme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }
}