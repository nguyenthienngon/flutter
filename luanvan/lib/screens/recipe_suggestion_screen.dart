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

  Color get primaryColor => isDarkMode ? Colors.blue[700]! : Colors.blue[500]!;
  Color get accentColor => isDarkMode ? Colors.cyan[600]! : Colors.cyan[400]!;
  Color get secondaryColor => isDarkMode ? Colors.grey[600]! : Colors.grey[400]!;
  Color get errorColor => isDarkMode ? Colors.red[400]! : Colors.red[600]!;
  Color get warningColor => isDarkMode ? Colors.amber[400]! : Colors.amber[600]!;
  Color get successColor => isDarkMode ? Colors.green[400]! : Colors.green[600]!;
  Color get currentBackgroundColor =>
      isDarkMode ? Colors.grey[900]! : Colors.white;
  Color get currentSurfaceColor => isDarkMode ? Colors.grey[800]! : Colors.grey[50]!;
  Color get currentTextPrimaryColor =>
      isDarkMode ? Colors.white : Colors.grey[900]!;
  Color get currentTextSecondaryColor =>
      isDarkMode ? Colors.grey[400]! : Colors.grey[600]!;
  List<Color> get chartColors => [
    Colors.blue[400]!,
    Colors.red[400]!,
    Colors.green[400]!,
    Colors.yellow[400]!,
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
  late Animation<double> _fadeAnimation;
  late Animation<double> _slideAnimation;
  late Animation<Offset> _headerSlideAnimation;

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
    {'id': 'morning', 'name': 'Morning'},
    {'id': 'afternoon', 'name': 'Afternoon'},
    {'id': 'evening', 'name': 'Evening'},
    {'id': 'other', 'name': 'Other'},
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

  Future<void> _initializeData() async {
    try {
      await _loadFavoriteRecipes();
      await _suggestRecipes();
    } catch (e, stackTrace) {
      _logger.e('Initialization error: $e', stackTrace: stackTrace);
      _showSnackBar(
          'Failed to initialize data. Please try again.', _themeColors.errorColor);
    }
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

    _headerAnimationController.forward();
    _animationController.forward();
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
        'name': item['foodName']?.toString() ?? 'Unknown item',
        'quantity': item['quantity'] ?? 0,
        'area': item['areaName']?.toString() ?? 'Unknown area',
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
          throw Exception('No recipes found');
        }

        final newRecipes = recipes.where((recipe) {
          final recipeId = recipe['id']?.toString();
          return recipeId != null && !excludeRecipeIds.contains(recipeId);
        }).toList();

        if (newRecipes.isEmpty) {
          throw Exception('No new recipes found after filtering');
        }

        final processedMeals = _processRecipes(newRecipes, excludeRecipeIds);
        return processedMeals;
      } else {
        throw Exception('API error: ${response.statusCode} - ${response.body}');
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
        'title': recipe['title']?.toString() ?? 'No title',
        'image': recipe['image']?.toString() ?? '',
        'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
        'ingredientsUsed': (recipe['ingredientsUsed'] as List<dynamic>?)?.map((e) => ({
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? '',
        })).toList() ??
            [],
        'ingredientsMissing':
        (recipe['ingredientsMissing'] as List<dynamic>?)?.map((e) => ({
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? '',
        })).toList() ??
            [],
        'instructions': recipe['instructions'] is List
            ? (recipe['instructions'] as List).whereType<String>().join('\n')
            : recipe['instructions']?.toString() ?? 'No instructions',
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
        ingredientsToUse = ['chicken', 'rice', 'carrot', 'onion'];
        _showSnackBar(
            'No ingredients available. Using defaults: ${ingredientsToUse.join(', ')}',
            _themeColors.warningColor);
      } else {
        _showSnackBar(
            'Using ${ingredientsToUse.length} ingredients: ${ingredientsToUse.join(', ')}',
            _themeColors.successColor);
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
          'Found ${meals.values.fold(0, (sum, meals) => sum + meals.length)} new recipes!',
          _themeColors.successColor);
    } catch (e, stackTrace) {
      _logger.e('Error suggesting recipes: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Failed to suggest recipes: $e';
        _mealPlan = {};
      });
      _showSnackBar('Failed to suggest recipes: $e', _themeColors.errorColor);
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
        _showSnackBar('Recipes refreshed successfully!', _themeColors.successColor);
      } else {
        throw Exception('Failed to reset recipe cache: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error resetting recipes: $e', stackTrace: stackTrace);
      setState(() {
        _errorMessage = 'Failed to reset recipes: $e';
      });
      _showSnackBar('Failed to reset recipes: $e', _themeColors.errorColor);
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
          _showSnackBar('Recipe not found in favorites.', _themeColors.errorColor);
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
          _showSnackBar('Removed from favorites!', _themeColors.successColor);
        } else {
          throw Exception('Failed to remove favorite recipe: ${response.body}');
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
          _showSnackBar('Recipe not found.', _themeColors.errorColor);
          return;
        }

        final payload = {
          'userId': widget.userId,
          'recipeId': recipeId,
          'title': recipe['title'] ?? 'No title',
          'imageUrl': recipe['image']?.toString() ?? '',
          'instructions': recipe['instructions'] ?? 'No instructions',
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
          _showSnackBar('Added to favorites!', _themeColors.successColor);
        } else {
          throw Exception('Failed to add favorite recipe: ${response.body}');
        }
      }
    } catch (e, stackTrace) {
      _logger.e('Error updating favorite recipe: $e', stackTrace: stackTrace);
      _showSnackBar('Failed to update favorite recipe: $e', _themeColors.errorColor);
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
            'No ingredients to add to shopping list.', _themeColors.successColor);
        return;
      }
      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/place_order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': widget.userId, 'items': missingIngredients}),
      );
      if (response.statusCode == 200) {
        _showSnackBar(
            'Added ${missingIngredients.length} ingredients to shopping list!',
            _themeColors.successColor);
      } else {
        throw Exception('Failed to add to shopping list: ${response.body}');
      }
    } catch (e, stackTrace) {
      _logger.e('Error adding to shopping list: $e', stackTrace: stackTrace);
      _showSnackBar('Failed to add to shopping list: $e', _themeColors.errorColor);
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
              backgroundColor == _themeColors.errorColor
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
                    'Advanced Options',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _themeColors.currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Available Ingredients',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _themeColors.currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_processedFoodItems.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'No ingredients in fridge.',
                        style: TextStyle(
                            color: _themeColors.currentTextSecondaryColor,
                            fontSize: 14),
                      ),
                    )
                  else
                    SizedBox(
                      height: 250,
                      child: ListView.builder(
                        itemCount: _processedFoodItems.length,
                        itemBuilder: (context, index) {
                          final item = _processedFoodItems[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            decoration: BoxDecoration(
                              color: item['selected']
                                  ? _themeColors.primaryColor.withOpacity(0.1)
                                  : _themeColors.currentSurfaceColor,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: item['selected']
                                    ? _themeColors.primaryColor
                                    : widget.isDarkMode
                                    ? Colors.grey[700]!
                                    : Colors.grey[300]!,
                                width: item['selected'] ? 2 : 1,
                              ),
                            ),
                            child: ListTile(
                              leading: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color:
                                  _getStatusColor(item['expiryDays']).withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Icon(
                                  Icons.fastfood,
                                  color: _getStatusColor(item['expiryDays']),
                                  size: 18,
                                ),
                              ),
                              title: Text(
                                item['name'],
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: _themeColors.currentTextPrimaryColor,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                'Area: ${item['area']}',
                                style: TextStyle(
                                    color: _themeColors.currentTextSecondaryColor,
                                    fontSize: 12),
                              ),
                              trailing: Checkbox(
                                value: item['selected'],
                                onChanged: (value) {
                                  setState(() {
                                    item['selected'] = value ?? false;
                                  });
                                  // Không gọi _suggestRecipes ở đây
                                },
                                activeColor: _themeColors.primaryColor,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    'Max Preparation Time (minutes)',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _themeColors.currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: widget.isDarkMode
                              ? Colors.grey[700]!
                              : Colors.grey[300]!,
                        ),
                      ),
                      filled: true,
                      fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                      hintText: 'Enter max time (e.g., 30)',
                      hintStyle: TextStyle(
                          color: _themeColors.currentTextSecondaryColor,
                          fontSize: 14),
                    ),
                    style: TextStyle(
                        color: _themeColors.currentTextPrimaryColor,
                        fontSize: 14),
                    onChanged: (value) {
                      setState(() {
                        _maxReadyTime = int.tryParse(value);
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                          colors: [_themeColors.primaryColor, _themeColors.accentColor]),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: _themeColors.primaryColor.withOpacity(0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _isLoading
                          ? null
                          : () {
                        Navigator.pop(context);
                        _suggestRecipes(); // Gọi tìm kiếm ở đây
                      },
                      icon: _isLoading
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                          : const Icon(Icons.search, color: Colors.white, size: 20),
                      label: Text(
                        _isLoading ? 'Searching...' : 'Apply and Search Recipes',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
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

  void _showRecipeDetails(Map<String, dynamic> recipe) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          recipe['title'] ?? 'No title',
                          style: TextStyle(
                            fontSize: 22,
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
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                            : Icon(
                          recipe['isFavorite'] ?? false
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: (recipe['isFavorite'] ?? false)
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
                          _toggleFavorite(recipe['id'].toString(),
                              !(recipe['isFavorite'] ?? false));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (recipe['image']?.isNotEmpty ?? false)
                    Container(
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
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          recipe['image'],
                          height: 180,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) => Container(
                            height: 180,
                            color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
                            child: Icon(Icons.broken_image,
                                size: 40,
                                color: widget.isDarkMode
                                    ? Colors.grey[400]
                                    : Colors.grey[600]),
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
                        Icon(Icons.access_time,
                            color: _themeColors.primaryColor, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Preparation time: ${recipe['readyInMinutes'] ?? 'N/A'}',
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
                  if (recipe['nutrition']?.isNotEmpty ?? false)
                    _buildNutritionSection(recipe['nutrition']),
                  const SizedBox(height: 12),
                  if (recipe['ingredientsUsed']?.isNotEmpty ?? false)
                    _buildIngredientSection(
                      'Available Ingredients',
                      (recipe['ingredientsUsed'] as List<dynamic>)
                          .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                          .toList(),
                    ),
                  const SizedBox(height: 12),
                  if (recipe['ingredientsMissing']?.isNotEmpty ?? false)
                    _buildIngredientSection(
                      'Missing Ingredients',
                      (recipe['ingredientsMissing'] as List<dynamic>)
                          .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                          .toList(),
                      _themeColors.warningColor,
                      Icons.shopping_cart,
                    ),
                  const SizedBox(height: 16),
                  if (recipe['ingredientsMissing']?.isNotEmpty ?? false)
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: [_themeColors.accentColor, _themeColors.primaryColor]),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: _themeColors.accentColor.withOpacity(0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : () => _addToShoppingList(recipe),
                        icon: _isLoading
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                            : const Icon(Icons.add_shopping_cart,
                            color: Colors.white, size: 20),
                        label: Text(
                          _isLoading ? 'Adding...' : 'Add to Shopping List',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    'Instructions',
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
                          color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
                    ),
                    child: Text(
                      recipe['instructions'] ?? 'No instructions available',
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
          'Nutrition Information',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: _themeColors.currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 180,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!),
          ),
          child: nutrientData.values.every((value) => value == 0.0)
              ? Center(
            child: Text(
              'No nutrition data available',
              style: TextStyle(
                  color: _themeColors.currentTextSecondaryColor,
                  fontSize: 14),
            ),
          )
              : PieChart(
            PieChartData(
              sections: [
                PieChartSectionData(
                  value: nutrientData['Calories']!,
                  color: _themeColors.chartColors[0],
                  title: 'Calories',
                  titleStyle: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 50,
                ),
                PieChartSectionData(
                  value: nutrientData['Fat']!,
                  color: _themeColors.chartColors[1],
                  title: 'Fat',
                  titleStyle: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 50,
                ),
                PieChartSectionData(
                  value: nutrientData['Carbohydrates']!,
                  color: _themeColors.chartColors[2],
                  title: 'Carbs',
                  titleStyle: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 50,
                ),
                PieChartSectionData(
                  value: nutrientData['Protein']!,
                  color: _themeColors.chartColors[3],
                  title: 'Protein',
                  titleStyle: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  radius: 50,
                ),
              ],
              sectionsSpace: 2,
              centerSpaceRadius: 40,
              borderData: FlBorderData(show: false),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: filteredNutrients
              .map((nutrient) => Chip(
            label: Text(
              '${nutrient['name']}: ${nutrient['amount']?.toStringAsFixed(1) ?? '0.0'} ${nutrient['unit'] ?? ''}',
              style: TextStyle(
                  color: _themeColors.currentTextPrimaryColor,
                  fontSize: 12),
            ),
            backgroundColor: _themeColors.accentColor.withOpacity(0.1),
            side: BorderSide(color: _themeColors.accentColor.withOpacity(0.3)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
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
                color: color ?? _themeColors.primaryColor, size: 18),
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
        if (ingredients.isEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              title.contains('Available')
                  ? 'No ingredients available'
                  : 'No missing ingredients',
              style: TextStyle(
                  color: _themeColors.currentTextSecondaryColor, fontSize: 14),
            ),
          )
        else
          ...ingredients.map((ingredient) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: (color ?? _themeColors.primaryColor).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: (color ?? _themeColors.primaryColor).withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.circle,
                    color: color ?? _themeColors.primaryColor, size: 10),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ingredient,
                    style: TextStyle(
                        color: _themeColors.currentTextPrimaryColor,
                        fontSize: 14),
                  ),
                ),
              ],
            ),
          )),
      ],
    );
  }

  Color _getStatusColor(int expiryDays) {
    if (expiryDays < 0) return _themeColors.errorColor;
    if (expiryDays <= 3) return _themeColors.warningColor;
    return _themeColors.successColor;
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
            color: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
          ),
          child: recipe['image']?.isNotEmpty ?? false
              ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
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
              : Icon(Icons.restaurant,
              color: _themeColors.primaryColor, size: 24),
        ),
        title: Text(
          recipe['title'] ?? 'No title',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _themeColors.currentTextPrimaryColor,
            fontSize: 14,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: Icon(
            (recipe['isFavorite'] ?? false) ? Icons.favorite : Icons.favorite_border,
            color: (recipe['isFavorite'] ?? false)
                ? _themeColors.errorColor
                : _themeColors.currentTextSecondaryColor,
            size: 24,
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
        onTap: () => _showRecipeDetails(recipe),
      ),
    );
  }

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
      highlightColor: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[100]!,
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
            trailing: Container(
              width: 24,
              height: 24,
              color: Colors.grey[300]!,
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
              color: _themeColors.currentSurfaceColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05),
                  blurRadius: 4,
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
                            _themeColors.primaryColor.withOpacity(0.3),
                            Colors.blue[100]!,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, color: _themeColors.primaryColor, size: 18),
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
                const SizedBox(height: 12),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
              colors: [_themeColors.primaryColor, _themeColors.accentColor])
              : null,
          color: isSelected
              ? null
              : widget.isDarkMode
              ? Colors.grey[700]!
              : Colors.grey[200]!,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : widget.isDarkMode
                ? Colors.grey[400]!
                : Colors.grey[300]!,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected
                ? Colors.white
                : _themeColors.currentTextPrimaryColor,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyScreen() {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(20),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _themeColors.currentSurfaceColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(2, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _themeColors.primaryColor.withOpacity(0.2),
                    _themeColors.primaryColor.withOpacity(0.1),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.restaurant_menu,
                size: 48,
                color: _themeColors.primaryColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No ingredients or recipes found',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: _themeColors.currentTextPrimaryColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Please add ingredients in Advanced Options.',
              style: TextStyle(
                fontSize: 14,
                color: _themeColors.currentTextSecondaryColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [_themeColors.primaryColor, _themeColors.accentColor],
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: _themeColors.primaryColor.withOpacity(0.5),
                    blurRadius: 4,
                    offset: const Offset(1, 2),
                  ),
                ],
              ),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: null,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onPressed: _isLoading ? null : _suggestRecipes,
                icon: const Icon(Icons.refresh, color: Colors.white, size: 20),
                label: const Text(
                  'Try Again',
                  style: TextStyle(
                    fontSize: 16,
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
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'No recipes available for this time slot.',
          style: TextStyle(
            fontSize: 14,
            color: _themeColors.currentTextSecondaryColor,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: _themeColors.currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 12),
        ...meals.map((recipe) => _buildRecipeTile(recipe)),
      ],
    );
  }

  Widget _buildRecipeCard(Map<String, dynamic> recipe) {
    return _buildRecipeTile(recipe);
  }

  @override
  Widget build(BuildContext context) {
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
                child: Stack(
                  children: [
                    Positioned(
                      top: -40,
                      right: -40,
                      child: Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.3),
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
                          color: Colors.white.withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.3),
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
                          const SizedBox(width: 8),
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
                                        Colors.white.withOpacity(0.3),
                                        Colors.white.withOpacity(0.1),
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
                                  'Recipe Suggestions',
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
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? _buildShimmerLoading()
                  : _processedFoodItems.isEmpty && _errorMessage == null
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
                              title: 'Advanced Options',
                              icon: Icons.tune,
                              child: Column(
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        'Filter Ingredients',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: _themeColors
                                              .currentTextPrimaryColor,
                                        ),
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          _isAdvancedOptionsVisible
                                              ? Icons.expand_less
                                              : Icons.expand_more,
                                          color:
                                          _themeColors.primaryColor,
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
                                        _themeColors.primaryColor,
                                        _themeColors.accentColor,
                                      ]),
                                      borderRadius:
                                      BorderRadius.circular(8),
                                      boxShadow: [
                                        BoxShadow(
                                          color: _themeColors.primaryColor
                                              .withOpacity(0.3),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: ElevatedButton.icon(
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor:
                                        Colors.transparent,
                                        shadowColor: Colors.transparent,
                                        padding:
                                        const EdgeInsets.symmetric(
                                            vertical: 12),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                          BorderRadius.circular(8),
                                        ),
                                      ),
                                      onPressed:
                                      _isLoading ? null : _suggestRecipes,
                                      icon: _isLoading
                                          ? const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child:
                                        CircularProgressIndicator(
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
                                            ? 'Searching...'
                                            : 'Search New Recipes',
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
                                title: 'Suggested Recipes',
                                icon: Icons.star,
                                child: Column(
                                  crossAxisAlignment:
                                  CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Found ${_mealPlan.values.fold(
                                            0,
                                                (sum, recipes) =>
                                            sum + recipes.length,
                                          )} matching recipes',
                                          style: TextStyle(
                                            fontSize: 14,
                                            color: _themeColors
                                                .currentTextSecondaryColor,
                                          ),
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            Icons.refresh,
                                            color:
                                            _themeColors.primaryColor,
                                            size: 20,
                                          ),
                                          onPressed: _isLoading
                                              ? null
                                              : _resetAllRecipes,
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 16),
                                    ..._timeSlots.map((slot) =>
                                        _buildRecipeSection(
                                            slot['id']!, slot['name']!)),
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
        backgroundColor: _themeColors.primaryColor,
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

  @override
  void dispose() {
    _animationController.dispose();
    _headerAnimationController.dispose();
    _clearOffsetCache();
    _httpClient.close();
    super.dispose();
  }
}
