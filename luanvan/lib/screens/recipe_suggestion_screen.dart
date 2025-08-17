import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';
import 'package:shimmer/shimmer.dart';
import 'config.dart';
import 'favorite_recipes_screen.dart';

class ThemeColors {
  final bool isDarkMode;
  ThemeColors({required this.isDarkMode});

  // Using hex values for consistency
  Color get primary => isDarkMode ? const Color(0xFF1976D2) : const Color(0xFF2196F3); // Blue
  Color get accent => isDarkMode ? const Color(0xFF00BCD4) : const Color(0xFF00ACC1); // Cyan
  Color get secondary => isDarkMode ? const Color(0xFF757575) : const Color(0xFF9E9E9E); // Grey
  Color get error => isDarkMode ? const Color(0xFFD32F2F) : const Color(0xFFF44336); // Red
  Color get warning => isDarkMode ? const Color(0xFFFBC02D) : const Color(0xFFFFC107); // Amber
  Color get success => isDarkMode ? const Color(0xFF388E3C) : const Color(0xFF4CAF50); // Green

  Color get background => isDarkMode ? const Color(0xFF121212) : const Color(0xFFFFFFFF);
  Color get surface => isDarkMode ? const Color(0xFF1E1E1E) : const Color(0xFFF5F5F5);
  Color get textPrimary => isDarkMode ? const Color(0xFFFFFFFF) : const Color(0xFF212121);
  Color get textSecondary => isDarkMode ? const Color(0xFFBDBDBD) : const Color(0xFF757575);

  List<Color> get chartColors => [
    primary,
    error,
    success,
    secondary,
  ];
}

class RecipeSuggestionScreen extends StatefulWidget {
  final List<Map<String, dynamic>> foodItems;
  final String userId;
  final bool isDarkMode;
  const RecipeSuggestionScreen({
    super.key,
    required this.foodItems,
    required this.userId,
    required this.isDarkMode,
  });

  @override
  _RecipeSuggestionScreenState createState() => _RecipeSuggestionScreenState();
}

class _RecipeSuggestionScreenState extends State<RecipeSuggestionScreen>
    with TickerProviderStateMixin {
  late AnimationController _animationController;
  late AnimationController _headerAnimationController;
  late AnimationController _searchButtonController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;
  late Animation<Offset> _headerSlideAnimation;
  late Animation<double> _searchButtonScaleAnimation;

  late List<Map<String, dynamic>> _processedFoodItems;
  Map<String, List<Map<String, dynamic>>> _mealPlan = {};
  Map<String, List<String>> _seenRecipeIds = {
    'morning': [],
    'afternoon': [],
    'evening': [],
    'other': [],
  };

  bool _isLoading = false;
  bool _isAdvancedOptionsVisible = false;
  String? _errorMessage;
  Set<String> _favoriteRecipeIds = {};
  int? _maxReadyTime;
  int _recipeOffset = 0;
  List<String> _selectedIngredients = [];

  final String _ngrokUrl = Config.getNgrokUrl();
  final Logger _logger = Logger();
  final http.Client _httpClient = http.Client();

  final List<Map<String, String>> _timeSlots = [
    {'id': 'morning', 'name': 'Buổi sáng'},
    {'id': 'afternoon', 'name': 'Buổi trưa'},
    {'id': 'evening', 'name': 'Buổi tối'},
    {'id': 'other', 'name': 'Khác'},
  ];

  ThemeColors get _themeColors => ThemeColors(isDarkMode: widget.isDarkMode);

  @override
  void initState() {
    super.initState();
    _logger.i('Ngrok URL: $_ngrokUrl');
    _initializeAnimations();
    _processedFoodItems = _processFoodItems();
    _initializeData();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _headerAnimationController.dispose();
    _searchButtonController.dispose();
    _clearOffsetCache();
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
    _searchButtonController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _slideAnimation = Tween<double>(begin: 20.0, end: 0.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _headerSlideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _headerAnimationController,
        curve: Curves.easeOut,
      ),
    );
    _searchButtonScaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _searchButtonController, curve: Curves.easeInOut),
    );
    _headerAnimationController.forward();
    _animationController.forward();
  }

  Future<void> _initializeData() async {
    try {
      await _loadFavoriteRecipes();
      await _suggestRecipes();
    } catch (e, stackTrace) {
      _logger.e('Initialization error: $e', stackTrace: stackTrace);
      _showSnackBar(
          'Không thể khởi tạo dữ liệu. Vui lòng thử lại.', _themeColors.error);
    }
  }

  List<Map<String, dynamic>> _processFoodItems() {
    return widget.foodItems
        .where((item) => item['foodName'] != null)
        .map((item) {
      int expiryDays = 999999;
      final expiryDateData = item['expiryDate'];
      if (expiryDateData != null) {
        try {
          DateTime? expiryDate;
          if (expiryDateData is String) {
            expiryDate = DateTime.tryParse(expiryDateData) ??
                DateTime.tryParse(expiryDateData.split('.')[0]);
          } else if (expiryDateData is DateTime) {
            expiryDate = expiryDateData;
          }
          if (expiryDate != null) {
            expiryDays = expiryDate.difference(DateTime.now()).inDays;
          } else {
            _logger.w(
                'Invalid expiry date for ${item['foodName'] ?? 'Unknown item'}');
          }
        } catch (e, stackTrace) {
          _logger.e('Error processing expiry date: $e',
              stackTrace: stackTrace);
        }
      } else {
        _logger.w('No expiry date for ${item['foodName'] ?? 'Unknown item'}');
      }
      return {
        'id': item['id']?.toString() ?? '',
        'name': item['foodName']?.toString() ?? 'Nguyên liệu không xác định',
        'quantity': item['quantity'] ?? 0,
        'area': item['areaName']?.toString() ?? 'Khu vực không xác định',
        'expiryDays': expiryDays,
        'selected': false,
      };
    })
        .where((item) => item['expiryDays'] > 0)
        .toList();
  }

  Future<void> _loadFavoriteRecipes() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final favorites = List<Map<String, dynamic>>.from(data['favoriteRecipes'] ?? []);
        setState(() {
          _favoriteRecipeIds = favorites.map((r) => r['recipeId'].toString()).toSet();
          _updateMealPlanFavorites(favorites);
        });
        _logger.i('Loaded ${favorites.length} favorite recipes');
      } else {
        _logger.w('Failed to load favorite recipes: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error loading favorite recipes: $e', stackTrace: stackTrace);
    }
  }

  void _updateMealPlanFavorites(List<Map<String, dynamic>> favorites) {
    for (var timeFrame in _mealPlan.keys) {
      final meals = _mealPlan[timeFrame];
      if (meals != null) {
        for (var recipe in meals) {
          final favorite = favorites.firstWhere(
                (f) => f['recipeId'] == recipe['id'],
            orElse: () => {},
          );
          if (favorite.isNotEmpty) {
            recipe['isFavorite'] = true;
            recipe['favoriteRecipeId'] = favorite['id']?.toString();
          }
        }
      }
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> _fetchRecipes({
    required http.Client client,
    required String ngrokUrl,
    required String userId,
    required List<String> ingredients,
    required int? maxReadyTime,
    required List<String> excludeRecipeIds,
    required int offset,
  }) async {
    final payload = {
      'ingredients': ingredients,
      if (maxReadyTime != null) 'maxReadyTime': maxReadyTime,
      'excludeRecipeIds': excludeRecipeIds,
      'offset': offset,
      'userId': userId,
      'random': DateTime.now().millisecondsSinceEpoch + Random().nextInt(10000),
    };
    _logger.d('Sending payload to API: ${jsonEncode(payload)}');
    try {
      final response = await client.post(
        Uri.parse('$ngrokUrl/suggest_simple_recipes'),
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
        },
        body: jsonEncode(payload),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final recipes = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
        _logger.i('Received ${recipes.length} recipes from backend');
        if (recipes.isEmpty) {
          throw Exception('Không tìm thấy công thức');
        }
        final newRecipes = recipes.where((recipe) {
          final recipeId = recipe['id']?.toString();
          return recipeId != null && !excludeRecipeIds.contains(recipeId);
        }).toList();
        if (newRecipes.isEmpty) {
          throw Exception('Không tìm thấy công thức mới sau khi lọc');
        }
        final processedMeals = _processRecipes(newRecipes, excludeRecipeIds);
        return processedMeals;
      } else {
        final errorData = jsonDecode(response.body);
        String errorMessage = errorData['error'] ?? 'Lỗi API: ${response.statusCode}';
        if (errorMessage == 'You need to provide at least 3 valid ingredients to suggest recipes') {
          errorMessage = 'Bạn cần cung cấp ít nhất 3 nguyên liệu để gợi ý công thức.';
        } else if (errorMessage == 'No recipes found. Please provide at least 3 valid ingredients.') {
          errorMessage = 'Không tìm thấy công thức. Vui lòng cung cấp ít nhất 3 nguyên liệu.';
        }
        throw Exception(errorMessage);
      }
    } catch (e, stackTrace) {
      _logger.e('Error fetching recipes: $e', stackTrace: stackTrace);
      rethrow;
    }
  }

  Map<String, List<Map<String, dynamic>>> _processRecipes(
      List<dynamic> recipes, List<String> excludeRecipeIds) {
    final Map<String, List<Map<String, dynamic>>> mealsByTimeFrame = {
      'morning': [],
      'afternoon': [],
      'evening': [],
      'other': [],
    };
    for (var recipe in recipes) {
      if (recipe is! Map<String, dynamic> ||
          recipe['id'] == null ||
          excludeRecipeIds.contains(recipe['id'].toString())) {
        _logger.w('Invalid or duplicate recipe: $recipe');
        continue;
      }
      final processedRecipe = {
        'id': recipe['id']?.toString() ?? 'unknown_${UniqueKey().toString()}',
        'title': recipe['title']?.toString() ?? 'Không có tiêu đề',
        'image': recipe['image']?.toString() ?? '',
        'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
        'ingredientsUsed': (recipe['ingredientsUsed'] as List<dynamic>?)?.map((e) => ({
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? '',
        })).toList() ??
            [],
        'ingredientsMissing': (recipe['ingredientsMissing'] as List<dynamic>?)?.map((e) => ({
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? '',
        })).toList() ??
            [],
        'instructions': recipe['instructions'] is List
            ? (recipe['instructions'] as List).whereType<String>().join('\n')
            : recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
        'isFavorite': _favoriteRecipeIds.contains(recipe['id']?.toString()),
        'timeSlot': recipe['timeSlot']?.toString()?.toLowerCase() ?? 'other',
        'nutrition': recipe['nutrition'] is List ? recipe['nutrition'] : [],
        'diets': recipe['diets'] is List ? recipe['diets'] : [],
      };
      final timeSlot = ['morning', 'afternoon', 'evening']
          .contains(processedRecipe['timeSlot'])
          ? processedRecipe['timeSlot'] as String
          : 'other';
      _logger.d(
          'Recipe: ${processedRecipe['title']}, received timeSlot: ${recipe['timeSlot']}, assigned to: $timeSlot');
      mealsByTimeFrame[timeSlot]!.add(processedRecipe);
      _logger.i('Added recipe ${processedRecipe['title']} to $timeSlot');
    }
    if (mealsByTimeFrame['morning']!.isEmpty ||
        mealsByTimeFrame['afternoon']!.isEmpty ||
        mealsByTimeFrame['evening']!.isEmpty) {
      final otherRecipes = mealsByTimeFrame['other']!;
      _logger.i('Redistributing ${otherRecipes.length} recipes from "other" slot');
      mealsByTimeFrame['other'] = [];
      int index = 0;
      for (var recipe in otherRecipes) {
        final slot = ['morning', 'afternoon', 'evening'][index % 3];
        recipe['timeSlot'] = slot;
        mealsByTimeFrame[slot]!.add(recipe);
        _logger.d('Redistributed recipe ${recipe['title']} to $slot');
        index++;
      }
    }
    _logger.i(
        'Meal plan after processing: ${mealsByTimeFrame.map((key, value) => MapEntry(key, value.length))}');
    return mealsByTimeFrame;
  }

  Future<void> _suggestRecipes({bool force = false}) async {
    if (_isLoading && !force) {
      _logger.i('Already suggesting recipes, skipping new request');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _selectedIngredients = _processedFoodItems
          .where((item) => item['selected'] == true)
          .map((item) => item['name'] as String)
          .toList();
    });

    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    _logger.i(
        '--- Suggesting recipes --- Request ID: $requestId, User ID: ${widget.userId}, Ingredients: $_selectedIngredients, Max ready time: $_maxReadyTime');

    try {
      List<String> ingredientsToUse = _selectedIngredients.isNotEmpty
          ? _selectedIngredients
          : _processedFoodItems.map((item) => item['name'] as String).toList();

      if (ingredientsToUse.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Bạn cần cung cấp ít nhất 3 nguyên liệu để gợi ý công thức.';
        });
        _showSnackBar(
            'Bạn cần cung cấp ít nhất 3 nguyên liệu để gợi ý công thức.',
            _themeColors.error);
        return;
      } else {
        _showSnackBar(
            'Sử dụng ${ingredientsToUse.length} nguyên liệu: ${ingredientsToUse.join(', ')}',
            _themeColors.success);
      }

      final meals = await _fetchRecipes(
        client: _httpClient,
        ngrokUrl: _ngrokUrl,
        userId: widget.userId,
        ingredients: ingredientsToUse,
        maxReadyTime: _maxReadyTime,
        excludeRecipeIds: _seenRecipeIds.values.expand((ids) => ids).toList(),
        offset: _recipeOffset,
      );

      setState(() {
        _mealPlan = meals;
        _recipeOffset += 20;
        meals.forEach((timeSlot, recipes) {
          _seenRecipeIds[timeSlot] = recipes.map((r) => r['id'].toString()).toList();
        });
      });
      _showSnackBar(
          'Tìm thấy ${meals.values.fold(0, (sum, meals) => sum + meals.length)} công thức mới!',
          _themeColors.success);
    } catch (e, stackTrace) {
      _logger.e('Error suggesting recipes: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _mealPlan = {};
      });
      _showSnackBar(_errorMessage!, _themeColors.error);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _resetAllRecipes() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _seenRecipeIds = {'morning': [], 'afternoon': [], 'evening': [], 'other': []};
      _mealPlan = {};
      _recipeOffset = 0;
      _selectedIngredients = [];
      for (var item in _processedFoodItems) {
        item['selected'] = false;
      }
    });

    try {
      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/reset_recipe_cache'),
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
        },
        body: jsonEncode({'userId': widget.userId}),
      );

      if (response.statusCode == 200) {
        await _suggestRecipes(force: true);
        _showSnackBar('Làm mới công thức thành công!', _themeColors.success);
      } else {
        throw Exception('Không thể làm mới cache công thức: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error resetting recipes: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Không thể làm mới công thức: $e';
      });
      _showSnackBar('Không thể làm mới công thức: $e', _themeColors.error);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
    _logger.i('Toggling favorite status for recipeId: $recipeId, isFavorite: $isFavorite');
    setState(() => _isLoading = true);
    try {
      if (isFavorite) {
        String? favoriteRecipeId;
        for (var timeFrame in _mealPlan.keys) {
          final meals = _mealPlan[timeFrame];
          if (meals != null) {
            final recipeIndex = meals.indexWhere((r) => r['id'] == recipeId);
            if (recipeIndex != -1 && meals[recipeIndex]['favoriteRecipeId'] != null) {
              favoriteRecipeId = meals[recipeIndex]['favoriteRecipeId'].toString();
              break;
            }
          }
        }
        if (favoriteRecipeId == null) {
          final response = await _httpClient.get(
            Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'),
          );
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            final favorites =
            List<Map<String, dynamic>>.from(data['favoriteRecipes'] ?? []);
            final favorite = favorites.firstWhere(
                  (f) => f['recipeId'] == recipeId,
              orElse: () => {},
            );
            favoriteRecipeId = favorite['id']?.toString();
          }
        }
        if (favoriteRecipeId == null) {
          _showSnackBar('Công thức không có trong danh sách yêu thích.', _themeColors.error);
          return;
        }

        final response = await _httpClient.delete(
          Uri.parse(
              '$_ngrokUrl/delete_favorite_recipe/$favoriteRecipeId?userId=${widget.userId}'),
          headers: {'Content-Type': 'application/json'},
        );

        if (response.statusCode == 200) {
          setState(() {
            _favoriteRecipeIds.remove(recipeId);
            for (var timeFrame in _mealPlan.keys) {
              final meals = _mealPlan[timeFrame];
              if (meals != null) {
                final recipeIndex = meals.indexWhere((r) => r['id'] == recipeId);
                if (recipeIndex != -1) {
                  meals[recipeIndex]['isFavorite'] = false;
                  meals[recipeIndex].remove('favoriteRecipeId');
                }
              }
            }
          });
          await _loadFavoriteRecipes();
          _showSnackBar('Đã xóa khỏi danh sách yêu thích!', _themeColors.success);
        } else {
          throw Exception('Không thể xóa công thức yêu thích: ${response.body}');
        }
      } else {
        Map<String, dynamic>? recipe;
        String? timeFrame;
        for (var tf in _mealPlan.keys) {
          final meals = _mealPlan[tf];
          if (meals != null) {
            final recipeIndex = meals.indexWhere((r) => r['id'] == recipeId);
            if (recipeIndex != -1) {
              recipe = meals[recipeIndex];
              timeFrame = tf;
              break;
            }
          }
        }
        if (recipe == null) {
          _showSnackBar('Không tìm thấy công thức.', _themeColors.error);
          return;
        }

        final payload = {
          'userId': widget.userId,
          'recipeId': recipeId,
          'title': recipe['title'] ?? 'Không có tiêu đề',
          'imageUrl': recipe['image']?.toString() ?? '',
          'instructions': recipe['instructions'] ?? 'Không có hướng dẫn',
          'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
          'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
          'readyInMinutes': recipe['readyInMinutes'] ?? 'N/A',
          'timeSlot': recipe['timeSlot'] ?? 'other',
          'nutrition': recipe['nutrition'] ?? [],
          'diets': recipe['diets'] ?? [],
        };

        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/add_favorite_recipe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );

        if (response.statusCode == 200) {
          final responseData = jsonDecode(response.body);
          final favoriteRecipeId =
              responseData['favoriteRecipeId']?.toString() ?? 'unknown_$recipeId';
          setState(() {
            _favoriteRecipeIds.add(recipeId);
            final meals = _mealPlan[timeFrame];
            if (meals != null) {
              final recipeIndex = meals.indexWhere((r) => r['id'] == recipeId);
              if (recipeIndex != -1) {
                meals[recipeIndex]['isFavorite'] = true;
                meals[recipeIndex]['favoriteRecipeId'] = favoriteRecipeId;
              }
            }
          });
          await _loadFavoriteRecipes();
          _showSnackBar('Đã thêm vào danh sách yêu thích!', _themeColors.success);
        } else {
          throw Exception('Không thể thêm công thức yêu thích: ${response.body}');
        }
      }
    } catch (e, stackTrace) {
      _logger.e('Error updating favorite recipe: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể cập nhật công thức yêu thích: $e', _themeColors.error);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<bool> _isFavorite(String recipeId) async {
    try {
      return _favoriteRecipeIds.contains(recipeId);
    } catch (e, stackTrace) {
      _logger.e('Error checking favorite status: $e', stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> _addToShoppingList(Map<String, dynamic> recipe) async {
    if (_isLoading) {
      _logger.i('Already adding to shopping list, skipping new request');
      return;
    }
    setState(() => _isLoading = true);
    try {
      final missingIngredients = (recipe['ingredientsMissing'] as List<dynamic>? ?? [])
          .map((e) => {
        'name': e['name']?.toString() ?? '',
        'amount': e['amount'] ?? 1,
        'unit': e['unit']?.toString() ?? '',
      })
          .toList();

      if (missingIngredients.isEmpty) {
        _showSnackBar(
            'Không có nguyên liệu nào cần thêm vào danh sách mua sắm.', _themeColors.success);
        return;
      }

      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/place_order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': widget.userId, 'items': missingIngredients}),
      );

      if (response.statusCode == 200) {
        _showSnackBar(
            'Đã thêm ${missingIngredients.length} nguyên liệu vào danh sách mua sắm!',
            _themeColors.success);
      } else {
        throw Exception('Không thể thêm vào danh sách mua sắm: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error adding to shopping list: $e', stackTrace: stackTrace);
      _showSnackBar('Không thể thêm vào danh sách mua sắm: $e', _themeColors.error);
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
              backgroundColor == _themeColors.error
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
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

  void _showAdvancedOptions(BuildContext context) {
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
          child: StatefulBuilder(
            builder: (BuildContext context, StateSetter setDialogState) {
              return SingleChildScrollView(
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
                      Text(
                        'Tùy chọn nâng cao',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: _themeColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Nguyên liệu có sẵn',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _themeColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_processedFoodItems.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _themeColors.background,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _themeColors.secondary.withOpacity(0.3)),
                          ),
                          child: Text(
                            'Không có nguyên liệu trong tủ lạnh.',
                            style: TextStyle(
                                color: _themeColors.textSecondary, fontSize: 15),
                          ),
                        )
                      else
                        SizedBox(
                          height: 280,
                          child: ListView.builder(
                            itemCount: _processedFoodItems.length,
                            itemBuilder: (context, index) {
                              final item = _processedFoodItems[index];
                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                decoration: BoxDecoration(
                                  color: item['selected']
                                      ? _themeColors.primary.withOpacity(0.1)
                                      : _themeColors.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: item['selected']
                                        ? _themeColors.primary
                                        : _themeColors.secondary.withOpacity(0.4),
                                    width: item['selected'] ? 2 : 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black
                                          .withOpacity(_themeColors.isDarkMode ? 0.1 : 0.03),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: ListTile(
                                  contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  leading: Container(
                                    width: 48,
                                    height: 48,
                                    decoration: BoxDecoration(
                                      color: _getStatusColor(item['expiryDays']).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      Icons.fastfood,
                                      color: _getStatusColor(item['expiryDays']),
                                      size: 24,
                                    ),
                                  ),
                                  title: Text(
                                    item['name'],
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: _themeColors.textPrimary,
                                      fontSize: 16,
                                    ),
                                  ),
                                  subtitle: Text(
                                    'Khu vực: ${item['area']}',
                                    style: TextStyle(
                                        color: _themeColors.textSecondary, fontSize: 13),
                                  ),
                                  trailing: Checkbox(
                                    value: item['selected'],
                                    onChanged: (value) {
                                      setDialogState(() {
                                        item['selected'] = value ?? false;
                                      });
                                    },
                                    activeColor: _themeColors.primary,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: 20),
                      Text(
                        'Thời gian chuẩn bị tối đa (phút)',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _themeColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: _themeColors.secondary.withOpacity(0.5),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: _themeColors.secondary.withOpacity(0.5),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: _themeColors.primary,
                              width: 2,
                            ),
                          ),
                          filled: true,
                          fillColor: _themeColors.background,
                          hintText: 'Nhập thời gian tối đa (ví dụ: 30)',
                          hintStyle: TextStyle(
                              color: _themeColors.textSecondary, fontSize: 15),
                        ),
                        style: TextStyle(color: _themeColors.textPrimary, fontSize: 15),
                        onChanged: (value) {
                          setDialogState(() {
                            _maxReadyTime = int.tryParse(value);
                          });
                        },
                      ),
                      const SizedBox(height: 24),
                      GestureDetector(
                        onTapDown: (_) => _searchButtonController.forward(),
                        onTapUp: (_) {
                          _searchButtonController.reverse();
                          if (!_isLoading) {
                            Navigator.pop(context);
                            _suggestRecipes();
                          }
                        },
                        onTapCancel: () => _searchButtonController.reverse(),
                        child: ScaleTransition(
                          scale: _searchButtonScaleAnimation,
                          child: Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                  colors: [_themeColors.primary, _themeColors.accent]),
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
                              onPressed: null,
                              icon: _isLoading
                                  ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                                  : const Icon(Icons.search, color: Colors.white, size: 24),
                              label: Text(
                                _isLoading ? 'Đang tìm kiếm...' : 'Áp dụng và tìm kiếm công thức',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
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
        expand: true,
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
                          recipe['isFavorite'] ?? false
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: (recipe['isFavorite'] ?? false)
                              ? _themeColors.error
                              : _themeColors.textSecondary,
                          size: 32,
                        ),
                        onPressed: _isLoading
                            ? null
                            : () {
                          setState(() {
                            recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
                          });
                          _toggleFavorite(recipe['id'].toString(),
                              !(recipe['isFavorite'] ?? false));
                        },
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
                            child: Icon(Icons.broken_image,
                                size: 48, color: _themeColors.textSecondary),
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
                  if (recipe['ingredientsMissing']?.isNotEmpty ?? false)
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: [_themeColors.accent, _themeColors.primary]),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: _themeColors.accent.withOpacity(0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : () => _addToShoppingList(recipe),
                        icon: _isLoading
                            ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                            : const Icon(Icons.add_shopping_cart,
                            color: Colors.white, size: 24),
                        label: Text(
                          _isLoading ? 'Đang thêm...' : 'Thêm vào danh sách mua sắm',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
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
    final filteredNutrients =
    nutrients.where((n) => n is Map && keyNutrients.contains(n['name'])).toList();
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

  Widget _buildIngredientSection(String title, List<String> ingredients,
      [Color? color, IconData? icon]) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon ?? Icons.check_circle,
                color: color ?? _themeColors.primary, size: 20),
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
              title.contains('có sẵn')
                  ? 'Không có nguyên liệu sẵn có'
                  : 'Không có nguyên liệu còn thiếu',
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
              border: Border.all(
                  color: (color ?? _themeColors.primary).withOpacity(0.3)),
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

  Color _getStatusColor(int expiryDays) {
    if (expiryDays < 0) return _themeColors.error;
    if (expiryDays <= 3) return _themeColors.warning;
    return _themeColors.success;
  }

  Widget _buildRecipeTile(Map<String, dynamic> recipe) {
    _logger.i('Building tile for recipe: ${recipe['title']}, timeSlot: ${recipe['timeSlot']}');
    if (recipe.isEmpty || recipe['title'] == null || recipe['id'] == null) {
      _logger.w('Invalid recipe, skipping: $recipe');
      return const SizedBox.shrink();
    }
    return Container(
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
                    (recipe['isFavorite'] ?? false) ? Icons.favorite : Icons.favorite_border,
                    color: (recipe['isFavorite'] ?? false)
                        ? _themeColors.error
                        : _themeColors.textSecondary,
                    size: 28,
                  ),
                  onPressed: _isLoading
                      ? null
                      : () {
                    _logger.i(
                        'Favorite button clicked in _buildRecipeTile, recipeId: ${recipe['id']}, isFavorite: ${recipe['isFavorite'] ?? false}');
                    setState(() {
                      recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
                    });
                    _toggleFavorite(
                        recipe['id'].toString(), !(recipe['isFavorite'] ?? false));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: _themeColors.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
      highlightColor: _themeColors.isDarkMode ? Colors.grey[700]! : Colors.grey[100]!,
      child: ListView.builder(
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
                    color: Colors.white,
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
                        color: Colors.white,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 14,
                        width: 150,
                        color: Colors.white,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 28,
                  height: 28,
                  color: Colors.white,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModernCard(
      {required String title, required IconData icon, required Widget child}) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, _) => Transform.translate(
        offset: Offset(0, _slideAnimation.value),
        child: Opacity(
          opacity: _fadeAnimation.value,
          child: Container(
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
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _themeColors.primary.withOpacity(0.3),
                            _themeColors.primary.withOpacity(0.1),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: _themeColors.primary, size: 20),
                    ),
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
                const SizedBox(height: 16),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModernChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(colors: [_themeColors.primary, _themeColors.accent])
              : null,
          color: isSelected ? null : _themeColors.background,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : _themeColors.secondary.withOpacity(0.5),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : _themeColors.textPrimary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 15,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyScreen() {
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
                Icons.restaurant_menu,
                size: 64,
                color: _themeColors.primary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Không tìm thấy nguyên liệu hoặc công thức',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _themeColors.textPrimary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              'Vui lòng thêm nguyên liệu trong Tùy chọn nâng cao.',
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
                onPressed: _isLoading
                    ? null
                    : () => _showAdvancedOptions(context),
                icon: const Icon(Icons.tune, color: Colors.white, size: 24),
                label: const Text(
                  'Thêm nguyên liệu',
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

  Widget _buildRecipeSection(String timeSlot, String label) {
    final meals = _mealPlan[timeSlot] ?? [];
    _logger.i('Displaying $timeSlot: ${meals.length} recipes');
    if (meals.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: _themeColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _themeColors.background,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _themeColors.secondary.withOpacity(0.3)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(_themeColors.isDarkMode ? 0.05 : 0.02),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                'Không có công thức cho khung giờ này.',
                style: TextStyle(
                  fontSize: 15,
                  color: _themeColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _themeColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          ...meals.map((recipe) => _buildRecipeTile(recipe)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _themeColors.background,
      body: SafeArea(
        child: Column(
          children: [
            SlideTransition(
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
                                  Icons.restaurant_menu,
                                  size: 24,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Gợi ý công thức',
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
            Expanded(
              child: _isLoading
                  ? _buildShimmerLoading()
                  : (_processedFoodItems.isEmpty && _errorMessage == null) ||
                  (_errorMessage != null &&
                      _errorMessage!.contains('cung cấp ít nhất 3 nguyên liệu'))
                  ? _buildEmptyScreen()
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
                            _buildModernCard(
                              title: 'Tùy chọn nâng cao',
                              icon: Icons.tune,
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Lọc nguyên liệu',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: _themeColors.textPrimary,
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          _isAdvancedOptionsVisible
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                          color: _themeColors.primary,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            _isAdvancedOptionsVisible =
                                            !_isAdvancedOptionsVisible;
                                          });
                                          if (_isAdvancedOptionsVisible) {
                                            _showAdvancedOptions(context);
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(colors: [
                                        _themeColors.primary,
                                        _themeColors.accent,
                                      ]),
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: [
                                        BoxShadow(
                                          color:
                                          _themeColors.primary.withOpacity(0.3),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        shadowColor: Colors.transparent,
                                        padding:
                                        const EdgeInsets.symmetric(vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                      ),
                                      onPressed: _isLoading ? null : _suggestRecipes,
                                      icon: _isLoading
                                          ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                          : const Icon(
                                        Icons.search,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                      label: Text(
                                        _isLoading
                                            ? 'Đang tìm kiếm...'
                                            : 'Tìm kiếm công thức mới',
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
                            const SizedBox(height: 16),
                            if (_mealPlan.isNotEmpty)
                              _buildModernCard(
                                title: 'Công thức được gợi ý',
                                icon: Icons.star,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Tìm thấy ${_mealPlan.values.fold(
                                            0,
                                                (sum, recipes) => sum + recipes.length,
                                          )} công thức phù hợp',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: _themeColors.textSecondary,
                                          ),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.refresh,
                                            color: _themeColors.primary,
                                            size: 20,
                                          ),
                                          onPressed: _isLoading ? null : _resetAllRecipes,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    ..._timeSlots.map((slot) =>
                                        _buildRecipeSection(slot['id']!, slot['name']!)),
                                  ],
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
      floatingActionButton: FloatingActionButton(
        backgroundColor: _themeColors.primary,
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => FavoriteRecipesScreen(
              userId: widget.userId,
              isDarkMode: widget.isDarkMode,
            ),
          ),
        ),
        child: const Icon(Icons.favorite_border, color: Colors.white),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Future<void> _clearOffsetCache() async {
    _logger.i('Đang xóa cache offset cho userId: ${widget.userId}');
    try {
      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/clear_offset'),
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
        },
        body: jsonEncode({'userId': widget.userId}),
      );
      if (response.statusCode == 200) {
        _logger.i('Xóa cache offset thành công cho userId: ${widget.userId}');
      } else {
        _logger.w('Không thể xóa cache offset: ${response.statusCode} - ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Lỗi khi xóa cache offset: $e', stackTrace: stackTrace);
    }
  }
}