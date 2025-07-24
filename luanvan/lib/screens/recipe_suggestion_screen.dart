import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:logger/logger.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shimmer/shimmer.dart';
import 'config.dart';
import 'favorite_recipes_screen.dart';

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

class _RecipeSuggestionScreenState extends State<RecipeSuggestionScreen> with TickerProviderStateMixin {
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
  bool _loading = false;
  bool _isAdvancedOptionsVisible = false;
  String? _error;
  Set<String> _favoriteRecipeIds = {};
  String? _selectedDiet;
  int? _targetCalories;
  int _recipeOffset = 0;

  List<String> _selectedIngredients = [];
  final String _ngrokUrl = Config.getNgrokUrl();
  final Logger _logger = Logger();
  final http.Client _httpClient = http.Client();

  final List<String> _diets = ['Vegetarian', 'Vegan', 'Gluten Free', 'Ketogenic', 'Pescatarian', 'Dairy Free', 'Palo'];
  final Map<String, String> _dietTranslations = {
    'Vegetarian': 'Ăn chay',
    'Vegan': 'Ăn chay thuần',
    'Gluten Free': 'Không gluten',
    'Ketogenic': 'Keto',
    'Pescatarian': 'Ăn cá',
    'Dairy Free': 'Không sữa',
    'Palo': 'Paleo',
  };
  final List<Map<String, String>> _timeSlots = [
    {'en': 'morning', 'vi': 'Sáng'},
    {'en': 'afternoon', 'vi': 'Trưa'},
    {'en': 'evening', 'vi': 'Tối'},
    {'en': 'other', 'vi': 'Có thể bạn sẽ thích'},
  ];

  Color get currentBackgroundColor => widget.isDarkMode ? const Color(0xFF121212) : const Color(0xFFE6F7FF);
  Color get currentSurfaceColor => widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white;
  Color get currentTextPrimaryColor => widget.isDarkMode ? const Color(0xFFE0E0E0) : const Color(0xFF202124);
  Color get currentTextSecondaryColor => widget.isDarkMode ? const Color(0xFFB0B0B0) : const Color(0xFF5F6368);

  final Color primaryColor = const Color(0xFF0078D7);
  final Color accentColor = const Color(0xFF00B294);
  final Color successColor = const Color(0xFF00C851);
  final Color warningColor = const Color(0xFFE67E22);
  final Color errorColor = const Color(0xFFE74C3C);
  final Color secondaryColor = const Color(0xFF50E3C2);

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _processedFoodItems = _processFoodItems();
    _loadFavoriteRecipes().then((_) => _suggestRecipes());
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
    ).animate(CurvedAnimation(
      parent: _headerAnimationController,
      curve: Curves.easeOut,
    ));

    _headerAnimationController.forward();
    _animationController.forward();
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
          } else {
            _logger.w('Invalid expiry date for ${item['foodName'] ?? 'Unknown ingredient'}');
          }
        } catch (e) {
          _logger.e('Error processing expiry date: $e', error: e, stackTrace: StackTrace.current);
        }
      } else {
        _logger.w('No expiry date for ${item['foodName'] ?? 'Unknown ingredient'}');
      }

      return {
        'id': item['id'] as String? ?? '',
        'name': item['foodName'] as String? ?? 'Unknown ingredient',
        'quantity': item['quantity'] ?? 0,
        'area': areaName,
        'expiryDays': expiryDays,
        'selected': false,
      };
    }).where((item) => item['expiryDays'] > 0).toList();
  }

  Future<void> _loadFavoriteRecipes() async {
    try {
      final response = await _httpClient.get(
        Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final favorites = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
        setState(() {
          _favoriteRecipeIds = favorites.map((r) => r['favoriteRecipeId'].toString()).toSet();
          for (var favorite in favorites) {
            for (var timeFrame in _mealPlan.keys) {
              final meals = _mealPlan[timeFrame] as List<Map<String, dynamic>>?;
              if (meals != null) {
                final recipeIndex = meals.indexWhere((r) => r['id'] == favorite['recipeId']);
                if (recipeIndex != -1) {
                  meals[recipeIndex]['isFavorite'] = true;
                  meals[recipeIndex]['favoriteRecipeId'] = favorite['favoriteRecipeId'];
                }
              }
            }
          }
        });
        _logger.i('Loaded ${_favoriteRecipeIds.length} favorite recipes');
      } else {
        _logger.w('Failed to load favorite recipes: ${response.body}');
      }
    } catch (e) {
      _logger.e('Error loading favorite recipes: $e', error: e, stackTrace: StackTrace.current);
    }
  }

  Future<Map<String, List<Map<String, dynamic>>>> _fetchRecipes(
      http.Client client,
      String ngrokUrl,
      String userId,
      List<String> ingredients,
      String? diet,
      int? maxCalories,
      List<String> excludeRecipeIds,
      int offset,
      ) async {
    final payload = {
      'ingredients': ingredients,
      if (diet != null) 'diet': diet.toLowerCase(),
      'maxCalories': maxCalories,
      'excludeRecipeIds': excludeRecipeIds,
      'offset': offset,
      'userId': userId,
      'random': DateTime.now().millisecondsSinceEpoch,
    };

    _logger.d('Payload sent to API: ${jsonEncode(payload)}');

    for (int attempt = 0; attempt < 3; attempt++) {
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
          final recipes = data['recipes'] as List<dynamic>? ?? [];
          _logger.i('Received ${recipes.length} recipes from backend: $recipes');
          if (recipes.isEmpty) {
            _logger.w('No new recipes, retrying attempt ${attempt + 1}');
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          return _processRecipes(recipes, excludeRecipeIds);
        } else {
          _logger.w('API response failed (attempt $attempt): ${response.statusCode}');
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        if (attempt < 2) {
          _logger.w('Error on attempt ${attempt + 1}: $e, retrying...');
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }
        throw Exception('Failed to call API after 3 attempts: $e');
      }
    }
    throw Exception('No valid response from API');
  }

  Map<String, List<Map<String, dynamic>>> _processRecipes(List<dynamic> recipes, List<String> excludeRecipeIds) {
    final Map<String, List<Map<String, dynamic>>> mealsByTimeFrame = {
      'morning': [],
      'afternoon': [],
      'evening': [],
      'other': [],
    };

    for (var recipe in recipes) {
      if (recipe is! Map<String, dynamic> || recipe['id'] == null || excludeRecipeIds.contains(recipe['id'].toString())) {
        _logger.w('Invalid or excluded recipe: $recipe');
        continue;
      }
      final processedRecipe = {
        'id': recipe['id'].toString(),
        'title': recipe['title']?.toString() ?? 'No title',
        'image': recipe['image']?.toString() ?? '',
        'readyInMinutes': recipe['readyInMinutes']?.toString() ?? 'N/A',
        'ingredientsUsed': (recipe['ingredientsUsed'] as List<dynamic>? ?? [])
            .map((e) => {
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? ''
        })
            .toList(),
        'ingredientsMissing': (recipe['ingredientsMissing'] as List<dynamic>? ?? [])
            .map((e) => {
          'name': e['name']?.toString() ?? '',
          'amount': e['amount'] ?? 0,
          'unit': e['unit']?.toString() ?? ''
        })
            .toList(),
        'instructions': recipe['instructions'] is List
            ? (recipe['instructions'] as List).whereType<String>().join('\n')
            : recipe['instructions']?.toString() ?? 'No instructions',
        'isFavorite': _favoriteRecipeIds.contains(recipe['id'].toString()),
        'timeSlot': recipe['timeSlot']?.toString() ?? 'other',
        'nutrition': recipe['nutrition'] ?? [],
        'diets': recipe['diets'] ?? [],
      };
      final timeSlot = ['morning', 'afternoon', 'evening'].contains(processedRecipe['timeSlot'])
          ? processedRecipe['timeSlot'] as String
          : 'other';
      mealsByTimeFrame[timeSlot] ??= [];
      mealsByTimeFrame[timeSlot]!.add(processedRecipe);
      _logger.i('Added recipe ${processedRecipe['title']} to time slot $timeSlot');
    }
    return mealsByTimeFrame;
  }

  Future<void> _suggestRecipes() async {
    if (_loading) {
      _logger.i('Suggest recipes already in progress, ignoring new request');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _selectedIngredients = _processedFoodItems
          .where((item) => item['selected'] == true)
          .map((item) => item['name'] as String)
          .toList();
    });

    final requestId = DateTime.now().millisecondsSinceEpoch.toString();
    _logger.i('--- Suggest Recipes --- Request ID: $requestId, User ID: ${widget.userId}, Ingredients: $_selectedIngredients, Diet: $_selectedDiet');

    try {
      List<String> ingredientsToUse = _selectedIngredients.isNotEmpty ? _selectedIngredients : [];
      if (ingredientsToUse.isEmpty && _processedFoodItems.isNotEmpty) {
        ingredientsToUse = _processedFoodItems
            .map((item) => item['name'] as String)
            .where((name) => name.isNotEmpty)
            .toList();
        _logger.i('Using all ingredients: $ingredientsToUse');
      }

      if (ingredientsToUse.isEmpty) {
        final response = await _httpClient.get(
          Uri.parse('$_ngrokUrl/get_fresh_ingredients?userId=${widget.userId}'),
        );
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          ingredientsToUse = (data['ingredients'] as List<dynamic>? ?? [])
              .map((item) => item['foodName']?.toString() ?? '')
              .where((name) => name.isNotEmpty)
              .toList();
        } else {
          _logger.w('Failed to fetch ingredients from backend: ${response.body}');
          _showSnackBar(context, 'Unable to fetch ingredients from fridge.', errorColor, Icons.error_outline);
          setState(() => _mealPlan = {});
          return;
        }
      }

      if (ingredientsToUse.isEmpty) {
        _logger.w('No ingredients available for recipe suggestion');
        _showSnackBar(context, 'Please select at least one ingredient.', errorColor, Icons.error_outline);
        setState(() => _mealPlan = {});
        return;
      }

      final meals = await _fetchRecipes(
        _httpClient,
        _ngrokUrl,
        widget.userId,
        ingredientsToUse,
        _selectedDiet,
        _targetCalories,
        _seenRecipeIds.values.expand((ids) => ids).toList(),
        _recipeOffset,
      );

      setState(() {
        _mealPlan = meals;
        _recipeOffset += meals.values.fold(0, (sum, list) => sum + list.length);
        meals.forEach((timeSlot, recipes) {
          _seenRecipeIds[timeSlot] = recipes.map((r) => r['id'].toString()).toList();
        });
        meals.forEach((timeSlot, recipes) {
          for (var recipe in recipes) {
            recipe['isFavorite'] = _favoriteRecipeIds.contains(recipe['id']);
          }
        });
      });

      _logger.i('Updated mealPlan with ${_mealPlan.values.fold(0, (sum, meals) => sum + meals.length)} recipes');
      _showSnackBar(context, 'Found ${meals.values.fold(0, (sum, meals) => sum + meals.length)} new recipes!', successColor, Icons.check_circle_outline);
    } catch (e, stackTrace) {
      _logger.e('Error suggesting recipes: $e\n$stackTrace');
      _showSnackBar(context, 'Error suggesting recipes: $e', errorColor, Icons.error_outline);
      setState(() => _mealPlan = {});
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _resetAllRecipes() async {
    if (_loading) {
      _logger.i('Reset recipes already in progress, ignoring new request');
      return;
    }

    setState(() {
      _seenRecipeIds = {'morning': [], 'afternoon': [], 'evening': [], 'other': []};
      _mealPlan = {};
      _recipeOffset = 0;
      for (var item in _processedFoodItems) {
        item['selected'] = false;
      }
      _selectedIngredients = [];
    });
    _logger.i('Reset _seenRecipeIds, _mealPlan, _recipeOffset, and _selectedIngredients');
    try {
      await _httpClient.post(
        Uri.parse('$_ngrokUrl/reset_recipe_cache'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': widget.userId}),
      );
      _logger.i('Requested backend to refresh recipe cache');
    } catch (e) {
      _logger.w('Failed to request cache refresh: $e');
    }
    await _suggestRecipes();
  }

  Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
    _logger.i('Starting _toggleFavorite, recipeId: $recipeId, isFavorite: $isFavorite');
    setState(() => _loading = true);
    try {
      if (isFavorite) {
        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/delete_favorite_recipe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'favorite_recipe_id': recipeId, 'userId': widget.userId}),
        );
        if (response.statusCode == 200) {
          setState(() {
            _favoriteRecipeIds.remove(recipeId);
            for (var timeFrame in _mealPlan.keys) {
              final meals = _mealPlan[timeFrame] as List<Map<String, dynamic>>?;
              if (meals != null) {
                final recipeIndex = meals.indexWhere((r) => r['id'] == recipeId);
                if (recipeIndex != -1) {
                  meals[recipeIndex]['isFavorite'] = false;
                }
              }
            }
          });
          _showSnackBar(context, 'Removed from favorites!', successColor, Icons.check_circle_outline);
        } else {
          throw Exception('Error removing favorite recipe: ${response.body}');
        }
      } else {
        Map<String, dynamic>? recipe;
        String? timeFrame;
        for (var tf in _mealPlan.keys) {
          final meals = _mealPlan[tf] as List<Map<String, dynamic>>?;
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
          _logger.w('Recipe not found for recipeId: $recipeId');
          _showSnackBar(context, 'Recipe not found to add to favorites.', errorColor, Icons.error_outline);
          return;
        }
        final payload = {
          'userId': widget.userId,
          'recipeId': recipeId,
          'title': recipe['title'] ?? 'No title',
          'imageUrl': recipe['image']?.toString() ?? '',
        };
        final response = await _httpClient.post(
          Uri.parse('$_ngrokUrl/add_favorite_recipe'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        );
        if (response.statusCode == 200) {
          setState(() {
            _favoriteRecipeIds.add(recipeId);
            final meals = _mealPlan[timeFrame] as List<Map<String, dynamic>>?;
            if (meals != null) {
              final recipeIndex = meals.indexWhere((r) => r['id'] == recipeId);
              if (recipeIndex != -1) {
                meals[recipeIndex]['isFavorite'] = true;
              }
            }
          });
          _showSnackBar(context, 'Added to favorites!', successColor, Icons.check_circle_outline);
        } else {
          throw Exception('Error adding favorite recipe: ${response.body}');
        }
      }
    } catch (e) {
      _logger.e('Error updating favorite recipe: $e', error: e, stackTrace: StackTrace.current);
      _showSnackBar(context, 'Error updating favorite recipe: $e', errorColor, Icons.error_outline);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<bool> _isFavorite(String recipeId) async {
    try {
      return _favoriteRecipeIds.contains(recipeId);
    } catch (e) {
      _logger.e('Error checking favorite recipe: $e', error: e, stackTrace: StackTrace.current);
      return false;
    }
  }

  Future<void> _addToShoppingList(Map<String, dynamic> recipe) async {
    if (_loading) {
      _logger.i('Add to shopping list already in progress, ignoring new request');
      return;
    }

    setState(() => _loading = true);
    try {
      final missingIngredients = (recipe['ingredientsMissing'] as List<dynamic>? ?? [])
          .map((e) => {
        'name': e['name']?.toString() ?? '',
        'amount': e['amount'] ?? 1,
        'unit': e['unit']?.toString() ?? '',
      })
          .toList();
      if (missingIngredients.isEmpty) {
        _showSnackBar(context, 'No ingredients to add to shopping list.', successColor, Icons.check_circle_outline);
        return;
      }
      final response = await _httpClient.post(
        Uri.parse('$_ngrokUrl/place_order'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': widget.userId, 'items': missingIngredients}),
      );
      if (response.statusCode == 200) {
        _showSnackBar(context, 'Added ${missingIngredients.length} ingredients to shopping list!', successColor, Icons.check_circle_outline);
      } else {
        throw Exception('Error adding to shopping list: ${response.body}');
      }
    } catch (e) {
      _logger.e('Error adding to shopping list: $e', error: e, stackTrace: StackTrace.current);
      _showSnackBar(context, 'Error adding to shopping list: $e', errorColor, Icons.error_outline);
    } finally {
      setState(() => _loading = false);
    }
  }

  void _showSnackBar(BuildContext context, String message, Color backgroundColor, IconData icon) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
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
            color: currentSurfaceColor,
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
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Available Ingredients',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: currentTextPrimaryColor,
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
                        style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
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
                              color: item['selected'] ? primaryColor.withOpacity(0.1) : currentSurfaceColor,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: item['selected'] ? primaryColor : widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                                width: item['selected'] ? 2 : 1,
                              ),
                            ),
                            child: ListTile(
                              leading: Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: _getStatusColor(item['expiryDays']).withOpacity(0.2),
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
                                  color: currentTextPrimaryColor,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                'Area: ${item['area']}',
                                style: TextStyle(color: currentTextSecondaryColor, fontSize: 12),
                              ),
                              trailing: Checkbox(
                                value: item['selected'],
                                onChanged: (value) {
                                  setState(() {
                                    item['selected'] = value ?? false;
                                  });
                                },
                                activeColor: primaryColor,
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
                    'Diet',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedDiet,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                        ),
                      ),
                      filled: true,
                      fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                    ),
                    hint: Text(
                      'Select diet',
                      style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
                    ),
                    items: _diets.map((diet) {
                      return DropdownMenuItem(
                        value: diet,
                        child: Text(_dietTranslations[diet] ?? diet, style: TextStyle(color: currentTextPrimaryColor, fontSize: 14)),
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
                    'Calorie Goal',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(
                          color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                        ),
                      ),
                      filled: true,
                      fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                      hintText: 'Enter calories (e.g., 2000)',
                      hintStyle: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
                    ),
                    style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                    onChanged: (value) {
                      setState(() {
                        _targetCalories = int.tryParse(value);
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [primaryColor, accentColor]),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withOpacity(0.3),
                          blurRadius: 6,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ElevatedButton.icon(
                      onPressed: _loading ? null : () {
                        Navigator.pop(context);
                        _suggestRecipes();
                      },
                      icon: _loading
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
                        _loading ? 'Searching...' : 'Apply and Search Recipes',
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
            color: currentSurfaceColor,
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
                            color: currentTextPrimaryColor,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          recipe['isFavorite'] ?? false ? Icons.favorite : Icons.favorite_border,
                          color: (recipe['isFavorite'] ?? false) ? errorColor : currentTextSecondaryColor,
                          size: 24,
                        ),
                        onPressed: _loading ? null : () {
                          setState(() {
                            recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
                          });
                          _toggleFavorite(recipe['id'].toString(), !(recipe['isFavorite'] ?? false));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (recipe['image'] != null && recipe['image'].isNotEmpty)
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
                            child: Icon(Icons.broken_image, size: 40, color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[600]),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.access_time, color: primaryColor, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Preparation time: ${recipe['readyInMinutes'] ?? 'N/A'} minutes',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (recipe['diets'] != null && (recipe['diets'] as List).isNotEmpty) _buildDietsSection(recipe['diets']),
                  const SizedBox(height: 12),
                  if (recipe['nutrition'] != null && (recipe['nutrition'] as List).isNotEmpty) _buildNutritionSection(recipe['nutrition']),
                  const SizedBox(height: 12),
                  if (recipe['ingredientsUsed'] != null)
                    _buildIngredientSection(
                      'Available Ingredients',
                      (recipe['ingredientsUsed'] as List<dynamic>)
                          .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                          .toList(),
                      successColor,
                      Icons.check_circle,
                    ),
                  const SizedBox(height: 12),
                  if (recipe['ingredientsMissing'] != null)
                    _buildIngredientSection(
                      'Missing Ingredients',
                      (recipe['ingredientsMissing'] as List<dynamic>)
                          .map((e) => '${e['name']} (${e['amount']} ${e['unit']})')
                          .toList(),
                      warningColor,
                      Icons.shopping_cart,
                    ),
                  const SizedBox(height: 16),
                  if ((recipe['ingredientsMissing'] as List<dynamic>? ?? []).isNotEmpty)
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(colors: [accentColor, primaryColor]),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: accentColor.withOpacity(0.3),
                            blurRadius: 6,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : () => _addToShoppingList(recipe),
                        icon: _loading
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                            : const Icon(Icons.add_shopping_cart, color: Colors.white, size: 20),
                        label: Text(
                          _loading ? 'Adding...' : 'Add Ingredients to Shopping List',
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
                      color: currentTextPrimaryColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
                    ),
                    child: Text(
                      recipe['instructions'] ?? 'No detailed instructions available',
                      style: TextStyle(
                        fontSize: 14,
                        color: currentTextPrimaryColor,
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

  Widget _buildDietsSection(List<dynamic> diets) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Suitable Diets',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: diets.map((diet) => Chip(
            label: Text(
              _dietTranslations[diet.toString()] ?? diet.toString(),
              style: TextStyle(color: currentTextPrimaryColor, fontSize: 12),
            ),
            backgroundColor: primaryColor.withOpacity(0.1),
            side: BorderSide(color: primaryColor.withOpacity(0.3)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          )).toList(),
        ),
      ],
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
          'Nutrition Information',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: currentTextPrimaryColor,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 180,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
          ),
          child: nutrientData.values.every((value) => value == 0.0)
              ? Center(
            child: Text(
              'No nutrition data available',
              style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
            ),
          )
              : BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              barGroups: [
                BarChartGroupData(
                  x: 0,
                  barRods: [
                    BarChartRodData(
                      toY: nutrientData['Calories']!,
                      color: const Color(0xFF36A2EB),
                      width: 14,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
                BarChartGroupData(
                  x: 1,
                  barRods: [
                    BarChartRodData(
                      toY: nutrientData['Fat']!,
                      color: const Color(0xFFFFCE56),
                      width: 14,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
                BarChartGroupData(
                  x: 2,
                  barRods: [
                    BarChartRodData(
                      toY: nutrientData['Carbohydrates']!,
                      color: const Color(0xFFFF6384),
                      width: 14,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
                BarChartGroupData(
                  x: 3,
                  barRods: [
                    BarChartRodData(
                      toY: nutrientData['Protein']!,
                      color: const Color(0xFF4BC0C0),
                      width: 14,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
              ],
              titlesData: FlTitlesData(
                show: true,
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, meta) {
                      const titles = ['Calories', 'Fat', 'Carbs', 'Protein'];
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          titles[value.toInt()],
                          style: TextStyle(
                            color: widget.isDarkMode ? Colors.white : Colors.black,
                            fontSize: 10,
                          ),
                        ),
                      );
                    },
                    reservedSize: 28,
                  ),
                ),
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 36,
                    getTitlesWidget: (value, meta) {
                      return Text(
                        value.toInt().toString(),
                        style: TextStyle(
                          color: widget.isDarkMode ? Colors.white : Colors.black,
                          fontSize: 10,
                        ),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              gridData: const FlGridData(show: false),
              borderData: FlBorderData(show: false),
              barTouchData: BarTouchData(enabled: false),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: filteredNutrients.map((nutrient) => Chip(
            label: Text(
              '${nutrient['name']}: ${nutrient['amount'] != null ? nutrient['amount'].toStringAsFixed(1) : '0.0'} ${nutrient['unit'] ?? ''}',
              style: TextStyle(color: currentTextPrimaryColor, fontSize: 12),
            ),
            backgroundColor: accentColor.withOpacity(0.1),
            side: BorderSide(color: accentColor.withOpacity(0.3)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          )).toList(),
        ),
      ],
    );
  }

  Widget _buildIngredientSection(String title, List<String> ingredients, Color color, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
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
              title.contains('Available') ? 'No available ingredients' : 'No missing ingredients',
              style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
            ),
          )
        else
          ...ingredients.map((ingredient) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.circle, color: color, size: 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ingredient,
                    style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                  ),
                ),
              ],
            ),
          )),
      ],
    );
  }

  Color _getStatusColor(int expiryDays) {
    if (expiryDays < 0) return errorColor;
    if (expiryDays <= 3) return warningColor;
    return successColor;
  }

  Widget _buildRecipeTile(Map<String, dynamic> recipe) {
    _logger.i('Rendering recipe: $recipe');
    if (recipe.isEmpty || recipe['title'] == null || recipe['id'] == null) {
      _logger.w('Invalid recipe, skipping: $recipe');
      return const SizedBox.shrink();
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: currentSurfaceColor,
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
            color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
          ),
          child: recipe['image'] != null && recipe['image'].isNotEmpty
              ? ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.network(
              recipe['image'],
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Icon(Icons.restaurant, color: primaryColor, size: 24),
            ),
          )
              : Icon(Icons.restaurant, color: primaryColor, size: 24),
        ),
        title: Text(
          recipe['title'] ?? 'No title',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: currentTextPrimaryColor,
            fontSize: 14,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: Icon(
            (recipe['isFavorite'] ?? false) ? Icons.favorite : Icons.favorite_border,
            color: (recipe['isFavorite'] ?? false) ? errorColor : currentTextSecondaryColor,
            size: 24,
          ),
          onPressed: _loading ? null : () {
            _logger.i('Heart button pressed in _buildRecipeTile, recipeId: ${recipe['id']}, isFavorite: ${recipe['isFavorite'] ?? false}');
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

  Widget _buildShimmerLoading() {
    return Shimmer.fromColors(
      baseColor: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
      highlightColor: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[100]!,
      child: ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 6,
        itemBuilder: (context, index) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: currentSurfaceColor,
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
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              title: Container(
                height: 16,
                width: double.infinity,
                color: Colors.grey[300],
              ),
              subtitle: Container(
                height: 12,
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8),
                color: Colors.grey[300],
              ),
              trailing: Container(
                width: 24,
                height: 24,
                color: Colors.grey[300],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildModernCard({required String title, required IconData icon, required Widget child}) {
    return AnimatedBuilder(
      animation: _fadeAnimation,
      builder: (context, _) {
        return Transform.translate(
          offset: Offset(0, _slideAnimation.value),
          child: Opacity(
            opacity: _fadeAnimation.value,
            child: Container(
              decoration: BoxDecoration(
                color: currentSurfaceColor,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [primaryColor.withOpacity(0.2), primaryColor.withOpacity(0.1)],
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(icon, color: primaryColor, size: 18),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: currentTextPrimaryColor,
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
      },
    );
  }
  Widget _buildModernChip({required String label, required bool isSelected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          gradient: isSelected ? LinearGradient(colors: [primaryColor, accentColor]) : null,
          color: isSelected ? null : widget.isDarkMode ? Colors.grey[700] : Colors.grey[200],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? Colors.transparent : widget.isDarkMode ? Colors.grey[600]! : Colors.grey[300]!,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : currentTextPrimaryColor,
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
          color: currentSurfaceColor,
          borderRadius: BorderRadius.circular(16),
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
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [primaryColor.withOpacity(0.2), primaryColor.withOpacity(0.1)],
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.restaurant_menu,
                size: 48,
                color: primaryColor,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No ingredients or recipes',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: currentTextPrimaryColor,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Add ingredients in advanced options.',
              style: TextStyle(
                fontSize: 14,
                color: currentTextSecondaryColor,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
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
                margin: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [primaryColor, accentColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withOpacity(0.4),
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
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.1),
                        ),
                      ),
                    ),
                    Positioned(
                      right: -16,
                      bottom: -24,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(0.05),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
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
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        gradient: RadialGradient(
                                          colors: [secondaryColor, Colors.white.withOpacity(0.3)],
                                          radius: 0.8,
                                        ),
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(
                                        Icons.restaurant_menu,
                                        color: Colors.white,
                                        size: 18,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Recipe Suggestions',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
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
              child: FutureBuilder(
                future: Future.value(_mealPlan),
                builder: (context, snapshot) {
                  if (_loading && _mealPlan.isEmpty) {
                    return _buildShimmerLoading();
                  }
                  if (_processedFoodItems.isEmpty) {
                    return _buildEmptyScreen();
                  }
                  _logger.i('Rendering ${_mealPlan.values.fold(0, (sum, meals) => sum + meals.length)} recipes in UI');
                  return CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: FadeTransition(
                          opacity: _fadeAnimation,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Column(
                              children: [
                                _buildModernCard(
                                  title: 'Advanced Options',
                                  icon: Icons.tune,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            _isAdvancedOptionsVisible = !_isAdvancedOptionsVisible;
                                          });
                                        },
                                        child: Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Advanced options',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: currentTextPrimaryColor,
                                              ),
                                            ),
                                            Icon(
                                              _isAdvancedOptionsVisible ? Icons.expand_less : Icons.expand_more,
                                              color: primaryColor,
                                              size: 24,
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_isAdvancedOptionsVisible) ...[
                                        const SizedBox(height: 12),
                                        Text(
                                          'Available Ingredients',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: currentTextPrimaryColor,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Select ingredients to find suitable recipes.',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: currentTextSecondaryColor,
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
                                              style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
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
                                                    color: item['selected'] ? primaryColor.withOpacity(0.1) : currentSurfaceColor,
                                                    borderRadius: BorderRadius.circular(10),
                                                    border: Border.all(
                                                      color: item['selected'] ? primaryColor : widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                                                      width: item['selected'] ? 2 : 1,
                                                    ),
                                                  ),
                                                  child: ListTile(
                                                    leading: Container(
                                                      width: 36,
                                                      height: 36,
                                                      decoration: BoxDecoration(
                                                        color: _getStatusColor(item['expiryDays']).withOpacity(0.2),
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
                                                        color: currentTextPrimaryColor,
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                    subtitle: Text(
                                                      'Area: ${item['area']}',
                                                      style: TextStyle(color: currentTextSecondaryColor, fontSize: 12),
                                                    ),
                                                    trailing: Checkbox(
                                                      value: item['selected'],
                                                      onChanged: (value) {
                                                        setState(() {
                                                          item['selected'] = value ?? false;
                                                        });
                                                      },
                                                      activeColor: primaryColor,
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
                                          'Diet',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: currentTextPrimaryColor,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        DropdownButtonFormField<String>(
                                          value: _selectedDiet,
                                          decoration: InputDecoration(
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(10),
                                              borderSide: BorderSide(
                                                color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                                              ),
                                            ),
                                            filled: true,
                                            fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                                          ),
                                          hint: Text(
                                            'Select diet',
                                            style: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
                                          ),
                                          items: _diets.map((diet) {
                                            return DropdownMenuItem(
                                              value: diet,
                                              child: Text(_dietTranslations[diet] ?? diet, style: TextStyle(color: currentTextPrimaryColor, fontSize: 14)),
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
                                          'Calorie Goal',
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold,
                                            color: currentTextPrimaryColor,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          keyboardType: TextInputType.number,
                                          decoration: InputDecoration(
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(10),
                                              borderSide: BorderSide(
                                                color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[300]!,
                                              ),
                                            ),
                                            filled: true,
                                            fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
                                            hintText: 'Enter calories (e.g., 2000)',
                                            hintStyle: TextStyle(color: currentTextSecondaryColor, fontSize: 14),
                                          ),
                                          style: TextStyle(color: currentTextPrimaryColor, fontSize: 14),
                                          onChanged: (value) {
                                            setState(() {
                                              _targetCalories = int.tryParse(value);
                                            });
                                          },
                                        ),
                                        const SizedBox(height: 16),
                                        Container(
                                          width: double.infinity,
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(colors: [primaryColor, accentColor]),
                                            borderRadius: BorderRadius.circular(10),
                                            boxShadow: [
                                              BoxShadow(
                                                color: primaryColor.withOpacity(0.3),
                                                blurRadius: 6,
                                                offset: const Offset(0, 3),
                                              ),
                                            ],
                                          ),
                                          child: ElevatedButton.icon(
                                            onPressed: _loading ? null : _suggestRecipes,
                                            icon: _loading
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
                                              _loading ? 'Searching...' : 'Search New Recipes',
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
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                                if (_mealPlan.isNotEmpty)
                                  _buildModernCard(
                                    title: 'Suggested Recipes',
                                    icon: Icons.restaurant,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Found ${_mealPlan.values.fold<int>(0, (sum, e) => sum + (e as List?)!.length ?? 0)} matching recipes.',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: currentTextSecondaryColor,
                                              ),
                                            ),
                                            IconButton(
                                              icon: Icon(Icons.refresh, color: primaryColor, size: 24),
                                              tooltip: 'Refresh recipes',
                                              onPressed: _loading ? null : _resetAllRecipes,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        ..._timeSlots.map((slot) {
                                          final meals = _mealPlan[slot['en']] as List<dynamic>? ?? [];
                                          if (meals.isEmpty) return const SizedBox.shrink();
                                          return Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                slot['vi']!,
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold,
                                                  color: currentTextPrimaryColor,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              ...meals.map((recipe) => _buildRecipeTile(recipe as Map<String, dynamic>)),
                                            ],
                                          );
                                        }),
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
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => FavoriteRecipesScreen(
                userId: widget.userId,
                isDarkMode: widget.isDarkMode,
              ),
            ),
          );
        },
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.favorite, size: 24),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
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