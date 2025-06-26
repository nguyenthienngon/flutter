import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'config.dart';

class FavoriteRecipesScreen extends StatefulWidget {
  final String userId;

  const FavoriteRecipesScreen({super.key, required this.userId});

  @override
  _FavoriteRecipesScreenState createState() => _FavoriteRecipesScreenState();
}

class _FavoriteRecipesScreenState extends State<FavoriteRecipesScreen> {
  List<Map<String, dynamic>> _favoriteRecipes = [];
  bool _isLoading = false;
  String? _error;
  late final String _ngrokUrl = Config.getNgrokUrl();

  @override
  void initState() {
    super.initState();
    _loadFavoriteRecipes();
  }

  Future<void> _loadFavoriteRecipes() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final response = await http.get(Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _favoriteRecipes = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
        });
      } else {
        throw Exception('Failed to load favorite recipes: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading favorite recipes: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteFavoriteRecipe(String favoriteRecipeId) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.post(
        Uri.parse('$_ngrokUrl/delete_favorite_recipe'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'favorite_recipe_id': favoriteRecipeId, 'userId': widget.userId}),
      );
      if (response.statusCode == 200) {
        setState(() {
          _favoriteRecipes.removeWhere((r) => r['id'] == favoriteRecipeId);
        });
      } else {
        throw Exception('Failed to delete favorite recipe: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Error deleting favorite recipe: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _updateFavoriteRecipe(String favoriteRecipeId, Map<String, dynamic> updatedRecipe) async {
    setState(() => _isLoading = true);
    try {
      final response = await http.put(
        Uri.parse('$_ngrokUrl/update_favorite_recipe/$favoriteRecipeId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': widget.userId, 'editedRecipe': updatedRecipe}),
      );
      if (response.statusCode == 200) {
        await _loadFavoriteRecipes(); // Tải lại danh sách để cập nhật UI
      } else {
        throw Exception('Failed to update favorite recipe: ${response.body}');
      }
    } catch (e) {
      setState(() {
        _error = 'Error updating favorite recipe: $e';
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _showEditRecipeDialog(Map<String, dynamic> recipe, String favoriteRecipeId) {
    final TextEditingController titleController = TextEditingController(text: recipe['title'] ?? 'No Title');
    final TextEditingController instructionsController = TextEditingController(text: recipe['instructions'] ?? 'No Instructions');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Recipe'),
        content: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 16),
                if (recipe['imageUrl'] != null)
                  SizedBox(
                    height: 200,
                    width: double.infinity,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        recipe['imageUrl'],
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Center(child: CircularProgressIndicator());
                        },
                        errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 100),
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: instructionsController,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Instructions'),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final updatedRecipe = {
                'title': titleController.text,
                'instructions': instructionsController.text,
                'imageUrl': recipe['imageUrl'],
                'ingredientsUsed': recipe['ingredientsUsed'] ?? [],
                'ingredientsMissing': recipe['ingredientsMissing'] ?? [],
                'readyInMinutes': recipe['readyInMinutes'],
                'servings': recipe['servings'],
              };
              _updateFavoriteRecipe(favoriteRecipeId, updatedRecipe);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ).then((_) => setState(() {}));
  }

  void _showRecipeDetails(Map<String, dynamic> recipe) {
    final List<String> allIngredients = [
      ...(recipe['ingredientsUsed'] ?? []),
      ...(recipe['ingredientsMissing'] ?? []),
    ];

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
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.9),
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
                    recipe['title'] ?? 'No Title',
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (recipe['imageUrl'] != null)
                    SizedBox(
                      height: 200,
                      width: double.infinity,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          recipe['imageUrl'],
                          fit: BoxFit.cover,
                          loadingBuilder: (context, child, loadingProgress) {
                            if (loadingProgress == null) return child;
                            return Center(child: CircularProgressIndicator());
                          },
                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 100),
                        ),
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
                  const Text('Nguyên liệu cần thiết:', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  for (var ingredient in allIngredients)
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorite Recipes'),
        backgroundColor: const Color(0xFF1976D2),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
          : _favoriteRecipes.isEmpty
          ? const Center(
        child: Text(
          'No favorite recipes yet.',
          style: TextStyle(fontSize: 18, color: Colors.grey),
        ),
      )
          : ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _favoriteRecipes.length,
        itemBuilder: (context, index) {
          final recipe = _favoriteRecipes[index];
          return Card(
            elevation: 4,
            margin: const EdgeInsets.only(bottom: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListTile(
              leading: recipe['imageUrl'] != null
                  ? ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 50,
                  height: 50,
                  child: Image.network(
                    recipe['imageUrl'],
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
                  ),
                ),
              )
                  : const Icon(Icons.restaurant),
              title: Text(
                recipe['title'] ?? 'No Title',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit, color: Colors.blue),
                    onPressed: () => _showEditRecipeDialog(recipe, recipe['id']),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deleteFavoriteRecipe(recipe['id']),
                  ),
                ],
              ),
              onTap: () {
                print('Tapped on recipe: ${recipe['title']}');
                _showRecipeDetails(recipe);
              },
            ),
          );
        },
      ),
    );
  }
}