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
  Map<String, List<Map<String, dynamic>>> _allCalendarMeals = {};
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
  DateTime? _selectedCalendarDate;
  Map<String, bool> _addedToCalendar = {};
  final Map<String, bool> _dayLoading = {};
  bool _showAdvancedOptions = false;

  final String _ngrokUrl = Config.getNgrokUrl();
  final Logger _logger = Logger();
  final http.Client _httpClient = http.Client();

  final List<String> _diets = ['Vegetarian', 'Vegan', 'Gluten Free', 'Ketogenic', 'Pescatarian'];
  final List<String> _timeFrames = ['day', 'week'];
  final Map<String, String> _timeFrameTranslations = {
    'day': '1 Ngày',
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
      await _loadAllCalendarMeals();
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
        headers: {'Content-Type': 'application/json'},
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
        headers: {'Content-Type': 'application/json'},
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

  Future<void> _loadAllCalendarMeals() async {
    setState(() => _isLoading = true);
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/get_all_calendar_meals?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );
      _logger.i('Response from get_all_calendar_meals: status=${response.statusCode}, body=${response.body}');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final mealsByDate = <String, List<Map<String, dynamic>>>{};
        final daysWithRecipes = <String>{};
        for (var meal in (data['meals'] as List<dynamic>)) {
          final date = meal['date'] as String;
          mealsByDate[date] = (meal['meals'] as List<dynamic>)
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          daysWithRecipes.add(date);
          _addedToCalendar[date] = true;
        }
        setState(() {
          _allCalendarMeals = mealsByDate;
          _calendarDaysWithRecipes = daysWithRecipes;
        });
        _logger.i('Loaded ${_allCalendarMeals.length} days with meals');
      } else {
        _logger.w('Failed to load calendar meals: ${response.body}');
        _showSnackBar('Failed to load calendar: ${response.body}', _themeColors.errorColor);
      }
    } catch (e, stackTrace) {
      _logger.e('Error loading calendar meals: $e', stackTrace: stackTrace);
      _showSnackBar('Failed to load calendar: $e', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteCalendarMeal(String date, String recipeId) async {
    setState(() => _isLoading = true);
    try {
      final response = await _httpClient.delete(
        Uri.parse('$_ngrokUrl/delete_meal_from_calendar?userId=${widget.userId}&date=$date&recipeId=$recipeId'),
        headers: {'Content-Type': 'application/json'},
      );
      if (response.statusCode == 200) {
        setState(() {
          _allCalendarMeals[date]?.removeWhere((meal) => meal['id'].toString() == recipeId);
          if (_allCalendarMeals[date]?.isEmpty ?? false) {
            _allCalendarMeals.remove(date);
            _calendarDaysWithRecipes.remove(date);
            _addedToCalendar[date] = false;
          }
        });
        _showSnackBar('Removed meal from calendar!', _themeColors.successColor);
      } else {
        throw Exception('Failed to delete meal: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error deleting meal: $e', stackTrace: stackTrace);
      _showSnackBar('Failed to delete meal: $e', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _deleteAllCalendarMeals() async {
    if (_isLoading) {
      _logger.i('Đang xử lý, bỏ qua yêu cầu xóa lịch');
      return;
    }

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _themeColors.currentSurfaceColor,
        title: Text('Xác nhận xóa lịch', style: TextStyle(color: _themeColors.currentTextPrimaryColor)),
        content: Text('Bạn có chắc muốn xóa toàn bộ lịch bữa ăn?', style: TextStyle(color: _themeColors.currentTextSecondaryColor)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: _themeColors.secondaryColor)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Xóa', style: TextStyle(color: _themeColors.errorColor)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      final response = await _httpClient.delete(
        Uri.parse('$_ngrokUrl/delete_all_calendar_meals?userId=${widget.userId}'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _allCalendarMeals.clear();
          _calendarDaysWithRecipes.clear();
          _addedToCalendar.clear();
          _mealPlan['week']?.clear();
        });
        _showSnackBar('Đã xóa toàn bộ lịch bữa ăn!', _themeColors.successColor);
      } else {
        throw Exception('Không thể xóa lịch: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi xóa lịch: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể xóa lịch.', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addToCalendar(Map<String, dynamic> recipe) async {
    if (_isLoading) return;

    _selectedCalendarDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      builder: (context, child) => Theme(
        data: ThemeData(
          colorScheme: ColorScheme.light(
            primary: _themeColors.primaryColor,
            onPrimary: Colors.white,
            surface: _themeColors.currentSurfaceColor,
            onSurface: _themeColors.currentTextPrimaryColor,
          ),
        ),
        child: child!,
      ),
    );

    if (_selectedCalendarDate == null) {
      _showSnackBar('No date selected.', _themeColors.warningColor);
      return;
    }

    setState(() => _isLoading = true);
    try {
      final dateStr = _selectedCalendarDate!.toIso8601String().split('T')[0];
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
        setState(() {
          _allCalendarMeals[dateStr] = (_allCalendarMeals[dateStr] ?? [])..add(recipe);
          _calendarDaysWithRecipes.add(dateStr);
          _addedToCalendar[dateStr] = true;
        });
        _showSnackBar('Added to calendar for $dateStr!', _themeColors.successColor);
      } else {
        throw Exception('Failed to add to calendar: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error adding to calendar: $e', stackTrace: stackTrace);
      _showSnackBar('Failed to add to calendar: $e', _themeColors.errorColor);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showCalendar() {
    _loadAllCalendarMeals().then((_) {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Container(
            decoration: BoxDecoration(
              color: _themeColors.currentSurfaceColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: SingleChildScrollView(
              controller: scrollController,
              child: Padding(
                padding: const EdgeInsets.all(16.0),
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
                    const SizedBox(height: 16),
                    Text(
                      'Lịch bữa ăn',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: _themeColors.currentTextPrimaryColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_allCalendarMeals.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Không có món ăn nào trong lịch.',
                          style: TextStyle(
                            color: _themeColors.currentTextSecondaryColor,
                            fontSize: 14,
                          ),
                        ),
                      )
                    else
                      ..._allCalendarMeals.entries.map((entry) {
                        final date = entry.key;
                        final meals = entry.value;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(DateTime.parse(date))}',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: _themeColors.currentTextPrimaryColor,
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(Icons.delete_forever, color: _themeColors.errorColor, size: 20),
                                  onPressed: _isLoading
                                      ? null
                                      : () async {
                                    final confirm = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        backgroundColor: _themeColors.currentSurfaceColor,
                                        title: Text('Xóa tất cả', style: TextStyle(color: _themeColors.currentTextPrimaryColor)),
                                        content: Text('Bạn có chắc muốn xóa tất cả công thức của ngày $date?',
                                            style: TextStyle(color: _themeColors.currentTextSecondaryColor)),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, false),
                                            child: Text('Hủy', style: TextStyle(color: _themeColors.secondaryColor)),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.pop(context, true),
                                            child: Text('Xóa', style: TextStyle(color: _themeColors.errorColor)),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirm == true) {
                                      _removeDayFromCalendar(DateTime.parse(date));
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...meals.map((meal) => Dismissible(
                              key: Key(meal['id'].toString()),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 16),
                                decoration: BoxDecoration(
                                  color: _themeColors.errorColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              confirmDismiss: (direction) async {
                                return await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    backgroundColor: _themeColors.currentSurfaceColor,
                                    title: Text('Xác nhận xóa', style: TextStyle(color: _themeColors.currentTextPrimaryColor)),
                                    content: Text('Bạn có chắc muốn xóa "${meal['title']}" khỏi lịch ngày $date?',
                                        style: TextStyle(color: _themeColors.currentTextSecondaryColor)),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, false),
                                        child: Text('Hủy', style: TextStyle(color: _themeColors.secondaryColor)),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.pop(context, true),
                                        child: Text('Xóa', style: TextStyle(color: _themeColors.errorColor)),
                                      ),
                                    ],
                                  ),
                                ) ?? false;
                              },
                              onDismissed: (direction) {
                                _deleteCalendarMeal(date, meal['id'].toString());
                              },
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                                  ),
                                  child: meal['image']?.isNotEmpty ?? false
                                      ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      meal['image'],
                                      fit: BoxFit.cover,
                                      errorBuilder: (context, error, stackTrace) => Icon(
                                        Icons.restaurant,
                                        color: _themeColors.primaryColor,
                                        size: 20,
                                      ),
                                    ),
                                  )
                                      : Icon(
                                    Icons.restaurant,
                                    color: _themeColors.primaryColor,
                                    size: 20,
                                  ),
                                ),
                                title: Text(
                                  meal['title'] ?? 'Không có tiêu đề',
                                  style: TextStyle(
                                    color: _themeColors.currentTextPrimaryColor,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  meal['timeSlot'] != null
                                      ? {'morning': 'Sáng', 'afternoon': 'Trưa', 'evening': 'Tối'}[meal['timeSlot']] ?? 'Khác'
                                      : 'Không xác định',
                                  style: TextStyle(
                                    color: _themeColors.currentTextSecondaryColor,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    Icons.delete,
                                    color: _themeColors.errorColor,
                                    size: 20,
                                  ),
                                  onPressed: _isLoading ? null : () => _deleteCalendarMeal(date, meal['id'].toString()),
                                ),
                                onTap: () => _showRecipeDetails(meal),
                              ),
                            )),
                            const SizedBox(height: 12),
                          ],
                        );
                      }),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
  Future<void> _generateWeeklyMealPlan() async {
    if (_isLoading) {
      _logger.i('Đang tạo kế hoạch bữa ăn, bỏ qua yêu cầu mới');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _addedToCalendar = {};
    });

    try {
      List<Map<String, dynamic>> ingredients = [];
      if (_useFridgeIngredients) {
        ingredients = await _fetchFridgeIngredients();
      }

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
        final mealPlanData = data['mealPlan'] as List<dynamic>? ?? [];
        _logger.i('Raw mealPlanData: $mealPlanData');
        final processedWeek = <String, List<Map<String, dynamic>>>{};

        for (var day in mealPlanData) {
          final date = day['day'] as String;
          final meals = day['meals'] as Map<String, dynamic>;
          final dateKey = date;
          processedWeek.putIfAbsent(dateKey, () => []);
          _addedToCalendar[dateKey] = false;
          for (var timeSlot in ['morning', 'afternoon', 'evening']) {
            final recipes = meals[timeSlot] as List<dynamic>? ?? [];
            for (var recipe in recipes) {
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
                })).toList() ??
                    [],
                'ingredientsMissing': recipe['ingredientsMissing']?.map((e) => ({
                  'name': e['name']?.toString() ?? '',
                  'amount': e['amount'] ?? 0,
                  'unit': e['unit']?.toString() ?? '',
                })).toList() ??
                    [],
                'extendedIngredients': recipe['extendedIngredients']?.map((e) => ({
                  'name': e['name']?.toString() ?? '',
                  'amount': e['amount'] ?? 0,
                  'unit': e['unit']?.toString() ?? '',
                })).toList() ??
                    [],
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

        setState(() {
          _mealPlan = {'week': processedWeek};
          _seenRecipeIds['week'] = processedWeek.values.expand((e) => e).map((r) => r['id'].toString()).toList();
          if (processedWeek.isNotEmpty) {
            _selectedDay = DateTime.parse(processedWeek.keys.first);
            _focusedDay = _selectedDay;
          }
        });
        _showSnackBar(
          'Đã tạo kế hoạch ${_timeFrameTranslations[_selectedTimeFrame]} với ${processedWeek.values.fold<int>(0, (sum, e) => sum + e.length)} công thức!',
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

  Future<void> _addDayToCalendar(DateTime date) async {
    final dateKey = date.toIso8601String().split('T')[0];
    if (_dayLoading[dateKey] == true) return;
    setState(() => _dayLoading[dateKey] = true);
    try {
      final mealsForDay = _allCalendarMeals[dateKey] ?? [];
      if (mealsForDay.isEmpty) {
        final meals = _mealPlan['week']?[dateKey] ?? [];
        _logger.i('Adding meals to calendar for date $dateKey: $meals');
        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/add_to_calendar'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'userId': widget.userId,
            'date': dateKey,
            'meals': meals,
          }),
        );
        _logger.i('Response from add_to_calendar: status=${response.statusCode}, body=${response.body}');
        if (response.statusCode == 200) {
          await _loadAllCalendarMeals();
          _showSnackBar('Đã thêm ngày vào lịch!', _themeColors.successColor);
        } else {
          _logger.w('Failed to add to calendar: ${response.body}');
          _showSnackBar('Không thể thêm vào lịch: ${response.body}', _themeColors.errorColor);
        }
      }
    } catch (e, stackTrace) {
      _logger.e('Error adding to calendar: $e', stackTrace: stackTrace);
      _showSnackBar('Lỗi khi thêm vào lịch: $e', _themeColors.errorColor);
    } finally {
      setState(() => _dayLoading[dateKey] = false);
    }
  }
  Future<void> _addAllToCalendar() async {
    if (_isLoading) {
      _logger.i('Đang xử lý, bỏ qua yêu cầu thêm tất cả vào lịch');
      return;
    }

    final meals = _mealPlan['week'];
    if (meals == null || meals.isEmpty) {
      _showSnackBar('Không có kế hoạch để thêm vào lịch.', _themeColors.warningColor);
      return;
    }

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _themeColors.currentSurfaceColor,
        title: Text('Xác nhận', style: TextStyle(color: _themeColors.currentTextPrimaryColor)),
        content: Text('Bạn muốn thêm toàn bộ kế hoạch ${_selectedTimeFrame == 'week' ? '7 ngày' : '1 ngày'} vào lịch?',
            style: TextStyle(color: _themeColors.currentTextSecondaryColor)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Hủy', style: TextStyle(color: _themeColors.secondaryColor)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Thêm', style: TextStyle(color: _themeColors.primaryColor)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoading = true);
    try {
      for (final dateKey in meals.keys) {
        final dayMeals = meals[dateKey]!;
        if (dayMeals.isEmpty) continue;

        setState(() => _dayLoading[dateKey] = true);
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
          setState(() {
            _calendarDaysWithRecipes.add(dateKey);
            _allCalendarMeals[dateKey] = dayMeals;
            _addedToCalendar[dateKey] = true;
          });
        } else {
          throw Exception('Không thể thêm ngày $dateKey vào lịch: ${response.body}');
        }
        setState(() => _dayLoading[dateKey] = false);
      }
      _showSnackBar('Đã thêm toàn bộ kế hoạch vào lịch!', _themeColors.successColor);
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi thêm tất cả vào lịch: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể thêm tất cả vào lịch.', _themeColors.errorColor);
    } finally {
      setState(() {
        _isLoading = false;
        _dayLoading.clear();
      });
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
        Uri.parse('$_ngrokUrl/delete_meal_from_calendar?userId=${widget.userId}&date=$dateKey'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        setState(() {
          _calendarDaysWithRecipes.remove(dateKey);
          _allCalendarMeals.remove(dateKey);
          _addedToCalendar[dateKey] = false;
        });
        _logger.i('Đã xóa tất cả công thức của ngày $dateKey khỏi lịch');
        _showSnackBar('Đã xóa ngày ${DateFormat('d MMMM, yyyy', 'vi_VN').format(day)} khỏi lịch!', _themeColors.successColor);
      } else {
        throw Exception('Không thể xóa khỏi lịch: ${response.body}');
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

    List<Map<String, dynamic>> meals = _allCalendarMeals[dateKey] ?? [];
    if (meals.isEmpty && _calendarDaysWithRecipes.contains(dateKey)) {
      setState(() => _isLoading = true);
      try {
        final response = await _httpClient.get(
          Uri.parse('$_ngrokUrl/get_calendar_meals?userId=${widget.userId}&date=$dateKey'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          meals = List<Map<String, dynamic>>.from(data['meals'] ?? []);
          setState(() {
            _allCalendarMeals[dateKey] = meals;
          });
          _logger.i('Meals from calendar for $dateKey: $meals');
        } else {
          throw Exception('Không thể tải công thức từ lịch: ${response.body}');
        }
      } catch (e, stackTrace) {
        _logger.e('Lỗi khi tải công thức từ lịch: $e', stackTrace: stackTrace);
        setState(() => _isLoading = false);
        return;
      } finally {
        setState(() => _isLoading = false);
      }
    }

    if (meals.isEmpty) {
      _showSnackBar('Không có công thức nào cho ngày này trong lịch.', _themeColors.warningColor);
      return;
    }

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

  Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
    setState(() => _isLoading = true);
    try {
      if (isFavorite) {
        final response = await _httpClient.delete(
          Uri.parse('$_ngrokUrl/delete_favorite_recipe/$recipeId'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'userId': widget.userId}),
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
          'relevanceScore': recipe['relevanceScore'] ?? 0.0,
        };

        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/add_favorite_recipe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
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
      })).toList() ??
          [];
      if (missingIngredients.isEmpty) {
        _showSnackBar('Không có nguyên liệu cần thêm.', _themeColors.successColor);
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

  final Map<String, Map<String, dynamic>> _recipeCache = {};
  Future<Map<String, dynamic>> _fetchMealDetails(String id) async {
    if (_recipeCache.containsKey(id)) {
      _logger.i('Returning cached meal details for id: $id');
      return _recipeCache[id]!;
    }
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/recipes/$id/information'),
        headers: {'Content-Type': 'application/json'},
      );
      _logger.i('Response for recipe $id: status=${response.statusCode}, body=${response.body}');
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        _recipeCache[id] = {
          'id': data['id'],
          'title': data['title'] ?? 'Không xác định',
          'image': data['image'] as String?,
          'readyInMinutes': data['readyInMinutes'] as int?,
          'ingredientsUsed': (data['ingredientsUsed'] as List<dynamic>?)?.map((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList() ?? [],
          'ingredientsMissing': (data['ingredientsMissing'] as List<dynamic>?)?.map((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList() ?? [],
          'extendedIngredients': (data['extendedIngredients'] as List<dynamic>?)?.map((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList() ?? [],
          'instructions': data['instructions'] is List
              ? (data['instructions'] as List).join('\n')
              : data['instructions'] as String? ?? 'Không có hướng dẫn chi tiết.',
          'nutrition': (data['nutrition'] as List<dynamic>?)?.map((e) => ({
            'name': e['name']?.toString() ?? '',
            'amount': e['amount'] ?? 0,
            'unit': e['unit']?.toString() ?? '',
          })).toList() ?? [],
          'diets': data['diets'] as List<dynamic>? ?? [],
          'relevanceScore': data['relevanceScore'] as double? ?? 0.0,
        };
        _logger.i('Fetched and cached meal details for id $id: ${_recipeCache[id]}');
        return _recipeCache[id]!;
      }
      throw Exception('Không thể tải chi tiết công thức: $id, status: ${response.statusCode}');
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi tải chi tiết công thức: $e', stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> _showRecipeDetails(Map<String, dynamic> recipe) async {
    _logger.i('Showing recipe details for recipe: ${recipe['title'] ?? 'Unknown'}, id: ${recipe['id'] ?? 'Unknown'}');

    if (recipe['id'] == null || recipe['title'] == null) {
      _logger.e('Invalid recipe data: $recipe');
      _showSnackBar('Dữ liệu công thức không hợp lệ.', _themeColors.errorColor);
      return;
    }

    bool isFetching = false;
    Map<String, dynamic> detailedRecipe = Map.from(recipe);

    if (detailedRecipe['instructions'] == null ||
        detailedRecipe['nutrition'] == null ||
        ((detailedRecipe['ingredientsUsed'] as List<dynamic>?)?.isEmpty ?? true) &&
            ((detailedRecipe['ingredientsMissing'] as List<dynamic>?)?.isEmpty ?? true) &&
            ((detailedRecipe['extendedIngredients'] as List<dynamic>?)?.isEmpty ?? true)) {
      setState(() {
        isFetching = true;
        _isLoading = true;
      });

      try {
        final fetchedDetails = await _fetchMealDetails(recipe['id'].toString());
        detailedRecipe = {...recipe, ...fetchedDetails};

        detailedRecipe['instructions'] ??= 'Không có hướng dẫn chi tiết.';
        detailedRecipe['nutrition'] ??= [
          {'name': 'Calories', 'amount': 0, 'unit': 'kcal'},
          {'name': 'Fat', 'amount': 0, 'unit': 'g'},
          {'name': 'Carbohydrates', 'amount': 0, 'unit': 'g'},
          {'name': 'Protein', 'amount': 0, 'unit': 'g'},
        ];
        detailedRecipe['ingredientsUsed'] ??= [];
        detailedRecipe['ingredientsMissing'] ??= [];
        detailedRecipe['extendedIngredients'] ??= [];
        detailedRecipe['readyInMinutes'] ??= 'N/A';
        detailedRecipe['title'] ??= 'Không có tiêu đề';
        detailedRecipe['image'] ??= '';
        detailedRecipe['diets'] ??= [];
        detailedRecipe['relevanceScore'] ??= 0.0;

        _logger.i('Updated recipe with fetched details: ${detailedRecipe['title']}');
      } catch (e, stackTrace) {
        _logger.e('Error fetching recipe details: $e', stackTrace: stackTrace);
        _showSnackBar('Không thể tải chi tiết công thức: $e', _themeColors.errorColor);
        setState(() {
          isFetching = false;
          _isLoading = false;
        });
        return;
      }
    }

    if (detailedRecipe['instructions'] is List) {
      detailedRecipe['instructions'] = (detailedRecipe['instructions'] as List).join('\n');
    }

    final requiredIngredients = [
      ...(detailedRecipe['ingredientsUsed'] as List<dynamic>? ?? []).map((e) =>
      '${e['name'] ?? 'Unknown'} (${e['amount'] ?? 0} ${e['unit'] ?? ''})'),
      ...(detailedRecipe['ingredientsMissing'] as List<dynamic>? ?? []).map((e) =>
      '${e['name'] ?? 'Unknown'} (${e['amount'] ?? 0} ${e['unit'] ?? ''})'),
      if (((detailedRecipe['ingredientsUsed'] as List<dynamic>?)?.isEmpty ?? true) &&
          ((detailedRecipe['ingredientsMissing'] as List<dynamic>?)?.isEmpty ?? true) &&
          ((detailedRecipe['extendedIngredients'] as List<dynamic>?)?.isNotEmpty ?? false))
        ...(detailedRecipe['extendedIngredients'] as List<dynamic>).map((e) =>
        '${e['name'] ?? 'Unknown'} (${e['amount'] ?? 0} ${e['unit'] ?? ''})'),
    ];

    _logger.i('Required ingredients for recipe ${detailedRecipe['id']}: $requiredIngredients');

    setState(() {
      isFetching = false;
      _isLoading = false;
    });

    await showModalBottomSheet(
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
                    color: widget.isDarkMode ? Colors.grey[400]! : Colors.grey[300]!,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                TabBar(
                  labelColor: _themeColors.primaryColor,
                  unselectedLabelColor: _themeColors.secondaryColor,
                  indicatorColor: _themeColors.primaryColor,
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
                              style: TextStyle(
                                fontSize: MediaQuery.of(context).size.width < 360 ? 11 : 12,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                              style: TextStyle(
                                fontSize: MediaQuery.of(context).size.width < 360 ? 11 : 12,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                              style: TextStyle(
                                fontSize: MediaQuery.of(context).size.width < 360 ? 11 : 12,
                                overflow: TextOverflow.ellipsis,
                              ),
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
                              style: TextStyle(
                                fontSize: MediaQuery.of(context).size.width < 360 ? 11 : 12,
                                overflow: TextOverflow.ellipsis,
                              ),
                              maxLines: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: isFetching
                      ? const Center(child: CircularProgressIndicator())
                      : TabBarView(
                    children: [
                      SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    detailedRecipe['title'].toString(),
                                    style: TextStyle(
                                      fontSize: MediaQuery.of(context).size.width < 360 ? 18 : 20,
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
                                    detailedRecipe['isFavorite'] == true
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: detailedRecipe['isFavorite'] == true
                                        ? _themeColors.errorColor
                                        : _themeColors.currentTextSecondaryColor,
                                    size: 20,
                                  ),
                                  onPressed: _isLoading
                                      ? null
                                      : () => _toggleFavorite(
                                    detailedRecipe['id'].toString(),
                                    detailedRecipe['isFavorite'] == true,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Hero(
                              tag: 'recipe_image_${detailedRecipe['id']}',
                              child: detailedRecipe['image'].toString().isNotEmpty
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
                                    detailedRecipe['image'].toString(),
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
                                    errorBuilder: (context, error, stackTrace) {
                                      _logger.e('Error loading image for recipe ${detailedRecipe['id']}: $error');
                                      return Container(
                                        height: 160,
                                        color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
                                        child: Icon(
                                          Icons.broken_image,
                                          size: 36,
                                          color: widget.isDarkMode ? Colors.grey[400]! : Colors.grey[600]!,
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              )
                                  : Container(
                                height: 160,
                                decoration: BoxDecoration(
                                  color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Center(
                                  child: Icon(
                                    Icons.restaurant,
                                    size: 36,
                                    color: widget.isDarkMode ? Colors.grey[400]! : Colors.grey[600]!,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: _themeColors.primaryColor.withAlpha(26),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.access_time, color: _themeColors.primaryColor, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Thời gian chuẩn bị: ${detailedRecipe['readyInMinutes'].toString()} phút',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: _themeColors.primaryColor,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            (detailedRecipe['nutrition'] as List<dynamic>?)?.isNotEmpty == true
                                ? _buildNutritionSection(detailedRecipe['nutrition'] as List<dynamic>)
                                : Text(
                              'Không có thông tin dinh dưỡng',
                              style: TextStyle(
                                fontSize: 13,
                                color: _themeColors.currentTextSecondaryColor,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SingleChildScrollView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            _buildIngredientsSection(
                              'Nguyên liệu cần thiết',
                              requiredIngredients,
                              _themeColors.primaryColor,
                              Icons.local_dining,
                            ),
                            const SizedBox(height: 12),
                            if ((detailedRecipe['ingredientsMissing'] as List<dynamic>?)?.isNotEmpty == true)
                              Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(colors: [_themeColors.accentColor, _themeColors.primaryColor]),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : () => _addToShoppingList(detailedRecipe),
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
                                        _isLoading ? 'Đang thêm...' : 'Thêm vào danh sách mua sắm',
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
                        controller: scrollController,
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Text(
                              'Hướng dẫn',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: _themeColors.currentTextPrimaryColor,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[50]!,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
                                ),
                              ),
                              child: Text(
                                detailedRecipe['instructions'].toString(),
                                style: TextStyle(
                                  fontSize: 13,
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
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Quản lý lịch',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: _themeColors.currentTextPrimaryColor,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(colors: [_themeColors.primaryColor, _themeColors.accentColor]),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ElevatedButton.icon(
                                onPressed: _isLoading ? null : () => _addToCalendar(detailedRecipe),
                                icon: _isLoading
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
                                  _isLoading ? 'Đang thêm...' : 'Thêm vào lịch',
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
                                gradient: LinearGradient(colors: [_themeColors.errorColor, _themeColors.warningColor]),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ElevatedButton(
                                onPressed: _isLoading
                                    ? null
                                    : () async {
                                  final dateKey = _selectedDay.toIso8601String().split('T')[0];
                                  if (_calendarDaysWithRecipes.contains(dateKey)) {
                                    await _removeDayFromCalendar(_selectedDay);
                                  } else {
                                    _showSnackBar('Ngày này chưa được thêm vào lịch.', _themeColors.warningColor);
                                  }
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: Text(
                                  _isLoading ? 'Đang xóa...' : 'Xóa ngày khỏi lịch',
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

  Widget _buildNutritionSection(List<dynamic> nutrients) {
    final keyNutrients = ['Calories', 'Fat', 'Carbohydrates', 'Protein'];
    final nutrientColors = [
      _themeColors.primaryColor,
      _themeColors.accentColor,
      _themeColors.successColor,
      _themeColors.secondaryColor,
    ];

    final filteredNutrients = nutrients.where((n) {
      return n is Map &&
          keyNutrients.contains(n['name']) &&
          n['amount'] is num &&
          n['amount'] > 0 &&
          n['unit'] is String;
    }).toList();

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

    if (filteredNutrients.isEmpty || nutrientData.values.every((value) => value == 0.0)) {
      return Text(
        'Không có thông tin dinh dưỡng hợp lệ',
        style: TextStyle(
          fontSize: 13,
          color: _themeColors.currentTextSecondaryColor,
        ),
      );
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final fontSize = screenWidth < 360 ? 10.0 : 12.0;
    final maxY = nutrientData.values.reduce((a, b) => a > b ? a : b) * 1.2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Dinh dưỡng',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: _themeColors.currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          height: 200,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[50]!,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(widget.isDarkMode ? 77 : 13),
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
                      width: screenWidth < 360 ? 16 : 20,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                      backDrawRodData: BackgroundBarChartRodData(
                        show: true,
                        toY: maxY,
                        color: widget.isDarkMode ? Colors.grey[900]! : Colors.grey[100]!,
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
                            label,
                            style: TextStyle(
                              color: _themeColors.currentTextPrimaryColor,
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
                    getTitlesWidget: (value, meta) {
                      return Text(
                        value.toInt().toString(),
                        style: TextStyle(
                          color: _themeColors.currentTextSecondaryColor,
                          fontSize: fontSize,
                        ),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(
                show: true,
                border: Border.all(
                  color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
                  width: 1,
                ),
              ),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                getDrawingHorizontalLine: (value) {
                  return FlLine(
                    color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!,
                    strokeWidth: 1,
                  );
                },
              ),
              barTouchData: BarTouchData(
                enabled: true,
                touchTooltipData: BarTouchTooltipData(
                  tooltipRoundedRadius: 8,
                  tooltipPadding: const EdgeInsets.all(8),
                  tooltipMargin: 8,
                  getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    return BarTooltipItem(
                      '${keyNutrients[groupIndex]}: ${rod.toY.toStringAsFixed(1)} ${filteredNutrients[groupIndex]['unit']}',
                      TextStyle(
                        color: _themeColors.currentTextPrimaryColor,
                        fontSize: fontSize,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  },
                ),
                touchCallback: (FlTouchEvent event, barTouchResponse) {
                  if (!event.isInterestedForInteractions ||
                      barTouchResponse == null ||
                      barTouchResponse.spot == null) {
                    return;
                  }
                  final index = barTouchResponse.spot!.touchedBarGroupIndex;
                  if (index >= 0 && index < keyNutrients.length) {
                    _showSnackBar(
                      '${keyNutrients[index]}: ${nutrientData[keyNutrients[index]]!.toStringAsFixed(1)} ${filteredNutrients[index]['unit']}',
                      _themeColors.successColor,
                    );
                  }
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        ...filteredNutrients.asMap().entries.map((entry) {
          final nutrient = entry.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  nutrient['name'].toString(),
                  style: TextStyle(
                    fontSize: 13,
                    color: _themeColors.currentTextPrimaryColor,
                  ),
                ),
                Text(
                  '${nutrient['amount']} ${nutrient['unit']}',
                  style: TextStyle(
                    fontSize: 13,
                    color: _themeColors.currentTextPrimaryColor,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
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
              'Không có nguyên liệu',
              style: TextStyle(
                color: _themeColors.currentTextSecondaryColor,
                fontSize: 14,
              ),
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
                color: (color ?? _themeColors.primaryColor).withAlpha(26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: (color ?? _themeColors.primaryColor).withAlpha(77)),
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
                      items[index],
                      style: TextStyle(
                        color: _themeColors.currentTextPrimaryColor,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }



  Widget _buildRecipeTile(Map<String, dynamic> recipe) {
    final recipeId = recipe['id'].toString();
    final isFavorite = _favoriteRecipeIds.contains(recipeId);

    return Dismissible(
      key: Key(recipeId),
      direction: DismissDirection.horizontal, // Cho phép kéo cả hai hướng
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          color: _themeColors.successColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.calendar_today, color: Colors.white),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        decoration: BoxDecoration(
          color: _themeColors.errorColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // Kéo từ trái sang phải để thêm vào lịch
          await _addToCalendar(recipe);
          return false; // Không xóa item sau khi thêm vào lịch
        } else {
          // Kéo từ phải sang trái để xóa
          return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              backgroundColor: _themeColors.currentSurfaceColor,
              title: Text('Xác nhận xóa', style: TextStyle(color: _themeColors.currentTextPrimaryColor)),
              content: Text(
                'Bạn có chắc muốn xóa "${recipe['title']}" khỏi kế hoạch?',
                style: TextStyle(color: _themeColors.currentTextSecondaryColor),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text('Hủy', style: TextStyle(color: _themeColors.secondaryColor)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text('Xóa', style: TextStyle(color: _themeColors.errorColor)),
                ),
              ],
            ),
          ) ?? false;
        }
      },
      onDismissed: (direction) {
        if (direction == DismissDirection.endToStart) {
          final dateKey = _selectedDay.toIso8601String().split('T')[0];
          _deleteCalendarMeal(dateKey, recipeId);
        }
      },
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
          ),
          child: recipe['image']?.isNotEmpty ?? false
              ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              recipe['image'],
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
          recipe['title'] ?? 'Không có tiêu đề',
          style: TextStyle(
            color: _themeColors.currentTextPrimaryColor,
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
            color: _themeColors.currentTextSecondaryColor,
            fontSize: 12,
          ),
        ),
        trailing: IconButton(
          icon: Icon(
            isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? _themeColors.errorColor : _themeColors.currentTextSecondaryColor,
            size: 20,
          ),
          onPressed: _isLoading ? null : () => _toggleFavorite(recipeId, isFavorite),
        ),
        onTap: () => _showRecipeDetails(recipe),
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _themeColors.currentBackgroundColor,
      appBar: AppBar(
        backgroundColor: _themeColors.currentSurfaceColor,
        title: SlideTransition(
          position: _headerSlideAnimation,
          child: Text(
            'Kế hoạch bữa ăn',
            style: TextStyle(
              color: _themeColors.currentTextPrimaryColor,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.calendar_today, color: _themeColors.primaryColor),
            onPressed: _showCalendar,
            tooltip: 'Xem lịch bữa ăn',
          ),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: _isLoading
            ? Center(
          child: CircularProgressIndicator(color: _themeColors.primaryColor),
        )
            : SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Advanced Options
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _showAdvancedOptions = !_showAdvancedOptions;
                    });
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _themeColors.currentSurfaceColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _themeColors.secondaryColor),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Tùy chọn nâng cao',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _themeColors.currentTextPrimaryColor,
                          ),
                        ),
                        Icon(
                          _showAdvancedOptions ? Icons.expand_less : Icons.expand_more,
                          color: _themeColors.primaryColor,
                        ),
                      ],
                    ),
                  ),
                ),
                if (_showAdvancedOptions) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Chế độ ăn',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _themeColors.currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedDiet,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _themeColors.currentSurfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _themeColors.secondaryColor),
                      ),
                    ),
                    hint: Text(
                      'Chọn chế độ ăn',
                      style: TextStyle(color: _themeColors.currentTextSecondaryColor),
                    ),
                    items: _diets.map((diet) {
                      return DropdownMenuItem(
                        value: diet,
                        child: Text(
                          diet,
                          style: TextStyle(color: _themeColors.currentTextPrimaryColor),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedDiet = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Calo mục tiêu',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: _themeColors.currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: _targetCalories.toString(),
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _themeColors.currentSurfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _themeColors.secondaryColor),
                      ),
                      suffixText: 'kcal',
                    ),
                    style: TextStyle(color: _themeColors.currentTextPrimaryColor),
                    onChanged: (value) {
                      setState(() {
                        _targetCalories = int.tryParse(value) ?? 2000;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    title: Text(
                      'Sử dụng nguyên liệu trong tủ lạnh',
                      style: TextStyle(
                        fontSize: 14,
                        color: _themeColors.currentTextPrimaryColor,
                      ),
                    ),
                    value: _useFridgeIngredients,
                    onChanged: (value) {
                      setState(() {
                        _useFridgeIngredients = value ?? false;
                      });
                    },
                    activeColor: _themeColors.primaryColor,
                    checkColor: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _selectedTimeFrame,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _themeColors.currentSurfaceColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: _themeColors.secondaryColor),
                      ),
                    ),
                    items: _timeFrames.map((timeFrame) {
                      return DropdownMenuItem(
                        value: timeFrame,
                        child: Text(
                          _timeFrameTranslations[timeFrame] ?? timeFrame,
                          style: TextStyle(color: _themeColors.currentTextPrimaryColor),
                        ),
                      );
                    }).toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedTimeFrame = value ?? 'week';
                      });
                    },
                  ),
                ],
                const SizedBox(height: 16),
                // Action Buttons
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _generateWeeklyMealPlan,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _themeColors.primaryColor,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(
                          _isLoading ? 'Đang tạo...' : 'Tạo kế hoạch',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),


                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _deleteAllCalendarMeals,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _themeColors.errorColor,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(
                          _isLoading ? 'Đang xóa...' : 'Xóa tất cả lịch',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // Error Message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _themeColors.errorColor.withAlpha(50),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: _themeColors.errorColor, fontSize: 14),
                    ),
                  ),
                const SizedBox(height: 16),
                // Calendar
                Container(
                  decoration: BoxDecoration(
                    color: _themeColors.currentSurfaceColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _themeColors.secondaryColor),
                  ),
                  child: TableCalendar(
                    locale: 'vi_VN',
                    firstDay: DateTime.now().subtract(const Duration(days: 365)),
                    lastDay: DateTime.now().add(const Duration(days: 365)),
                    focusedDay: _focusedDay,
                    selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
                    onDaySelected: (selectedDay, focusedDay) {
                      setState(() {
                        _selectedDay = selectedDay;
                        _focusedDay = focusedDay;
                      });
                      _showRecipesForDay(selectedDay);
                    },
                    calendarFormat: CalendarFormat.week,
                    headerStyle: HeaderStyle(
                      formatButtonVisible: false,
                      titleCentered: true,
                      titleTextStyle: TextStyle(
                        color: _themeColors.currentTextPrimaryColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    calendarStyle: CalendarStyle(
                      todayDecoration: BoxDecoration(
                        color: _themeColors.primaryColor.withOpacity(0.3),
                        shape: BoxShape.circle,
                      ),
                      selectedDecoration: BoxDecoration(
                        color: _themeColors.primaryColor,
                        shape: BoxShape.circle,
                      ),
                      markerDecoration: BoxDecoration(
                        color: _themeColors.accentColor,
                        shape: BoxShape.circle,
                      ),
                      defaultTextStyle: TextStyle(color: _themeColors.currentTextPrimaryColor),
                      weekendTextStyle: TextStyle(color: _themeColors.currentTextPrimaryColor),
                    ),
                    daysOfWeekStyle: DaysOfWeekStyle(
                      weekdayStyle: TextStyle(color: _themeColors.currentTextPrimaryColor),
                      weekendStyle: TextStyle(color: _themeColors.currentTextPrimaryColor),
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
                                color: _themeColors.accentColor,
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
                const SizedBox(height: 16),
                // Meal Plan Display
                if (_mealPlan['week']?.isNotEmpty ?? false)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Kế hoạch ${_timeFrameTranslations[_selectedTimeFrame]}',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: _themeColors.currentTextPrimaryColor,
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.add_circle, color: _themeColors.primaryColor),
                            onPressed: _isLoading ? null : _addAllToCalendar,
                            tooltip: 'Thêm tất cả vào lịch',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ..._mealPlan['week']!.entries.map((entry) {
                        final date = DateTime.parse(entry.key);
                        final meals = entry.value;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  DateFormat('d MMMM, yyyy', 'vi_VN').format(date),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: _themeColors.currentTextPrimaryColor,
                                  ),
                                ),
                                IconButton(
                                  icon: Icon(
                                    _addedToCalendar[entry.key] == true
                                        ? Icons.check_circle
                                        : Icons.add_circle_outline,
                                    color: _addedToCalendar[entry.key] == true
                                        ? _themeColors.successColor
                                        : _themeColors.primaryColor,
                                    size: 20,
                                  ),
                                  onPressed: _isLoading || _dayLoading[entry.key] == true
                                      ? null
                                      : () {
                                    if (_addedToCalendar[entry.key] == true) {
                                      _removeDayFromCalendar(date);
                                    } else {
                                      _addDayToCalendar(date);
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (meals.isEmpty)
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Không có công thức cho ngày này',
                                  style: TextStyle(
                                    color: _themeColors.currentTextSecondaryColor,
                                    fontSize: 14,
                                  ),
                                ),
                              )
                            else
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: meals.length,
                                itemBuilder: (context, index) => _buildRecipeTile(meals[index]),
                              ),
                            const SizedBox(height: 16),
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
                      border: Border.all(color: _themeColors.secondaryColor),
                    ),
                    child: Text(
                      'Chưa có kế hoạch bữa ăn. Nhấn "Tạo kế hoạch" để bắt đầu.',
                      style: TextStyle(
                        color: _themeColors.currentTextSecondaryColor,
                        fontSize: 14,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
          ),
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