import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class FavoriteRecipesScreen extends StatefulWidget {
  final String userId;

  const FavoriteRecipesScreen({super.key, required this.userId});

  @override
  _FavoriteRecipesScreenState createState() => _FavoriteRecipesScreenState();
}

class _FavoriteRecipesScreenState extends State<FavoriteRecipesScreen> {
  List<Map<String, dynamic>> _favoriteRecipes = [];
  final String _ngrokUrl = 'http://your-ngrok-url.ngrok.io'; // Thay bằng ngrok URL của bạn

  @override
  void initState() {
    super.initState();
    _loadFavoriteRecipes();
  }

  Future<void> _loadFavoriteRecipes() async {
    try {
      final response = await http.get(Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _favoriteRecipes = List<Map<String, dynamic>>.from(data['recipes'] ?? []);
        });
      }
    } catch (e) {
      print('Error loading favorite recipes: $e');
    }
  }

  Future<void> _deleteFavoriteRecipe(String favoriteRecipeId) async {
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
      }
    } catch (e) {
      print('Error deleting favorite recipe: $e');
    }
  }

  void _showRecipeDetails(Map<String, dynamic> recipe, String favoriteRecipeId) {
    TextEditingController titleController = TextEditingController(text: recipe['title'] ?? 'No Title');
    TextEditingController instructionsController = TextEditingController(text: recipe['instructions'] ?? 'No instructions');

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
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                const SizedBox(height: 16),
                if (recipe['imageUrl'] != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      recipe['imageUrl'],
                      height: 200,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image, size: 100),
                    ),
                  ),
                const SizedBox(height: 16),
                TextField(
                  controller: instructionsController,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Instructions'),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        final updatedRecipe = {
                          'title': titleController.text,
                          'instructions': instructionsController.text,
                          'editedRecipe': {
                            'title': titleController.text,
                            'instructions': instructionsController.text,
                          },
                        };
                        await _updateFavoriteRecipe(favoriteRecipeId, updatedRecipe);
                        Navigator.pop(context);
                      },
                      child: const Text('Save'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('Cancel', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _updateFavoriteRecipe(String favoriteRecipeId, Map<String, dynamic> updatedRecipe) async {
    try {
      final response = await http.put(
        Uri.parse('$_ngrokUrl/update_favorite_recipe/$favoriteRecipeId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'userId': widget.userId, 'editedRecipe': updatedRecipe}),
      );
      if (response.statusCode == 200) {
        await _loadFavoriteRecipes();
      }
    } catch (e) {
      print('Error updating favorite recipe: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Favorite Recipes'),
        backgroundColor: const Color(0xFF1976D2),
      ),
      body: _favoriteRecipes.isEmpty
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
                child: Image.network(
                  recipe['imageUrl'],
                  width: 50,
                  height: 50,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => const Icon(Icons.broken_image),
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
                    onPressed: () => _showRecipeDetails(recipe, recipe['id']),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _deleteFavoriteRecipe(recipe['id']),
                  ),
                ],
              ),
              onTap: () => _showRecipeDetails(recipe, recipe['id']),
            ),
          );
        },
      ),
    );
  }
}