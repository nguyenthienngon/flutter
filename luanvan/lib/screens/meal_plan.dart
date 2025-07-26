
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:logger/logger.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shimmer/shimmer.dart';
import 'config.dart';

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
late Animation<double> _scaleAnimation;

Map<String, dynamic> _mealPlan = {};
Map<String, List<String>> _seenRecipeIds = {'week': []};
bool _loading = false;
String? _error;
Set<String> _favoriteRecipeIds = {};
String? _selectedDiet;
int? _targetCalories;
String? _mealPlanId;
bool _useFridgeIngredients = false;
String _selectedTimeFrame = 'week';
final List<String> _timeFrames = ['day', 'three_days', 'week'];
final Map<String, String> _timeFrameTranslations = {
'day': '1 Ngày',
'three_days': '3 Ngày',
'week': 'Cả Tuần',
};

final String _ngrokUrl = Config.getNgrokUrl();
final Logger _logger = Logger();
final http.Client _httpClient = http.Client();
final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: ['https://www.googleapis.com/auth/calendar.events']);
GoogleSignInAccount? _googleUser;

final List<String> _diets = ['Vegetarian', 'Vegan', 'Gluten Free', 'Ketogenic', 'Pescatarian'];

Color get currentBackgroundColor => widget.isDarkMode ? const Color(0xFF121212) : const Color(0xFFE6F7FF);
Color get currentSurfaceColor => widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white;
Color get currentTextPrimaryColor => widget.isDarkMode ? const Color(0xFFE0E0E0) : const Color(0xFF202124);
Color get currentTextSecondaryColor => widget.isDarkMode ? const Color(0xFFB0B0B0) : const Color(0xFF5F6368);

final Color primaryColor = const Color(0xFF0078D7);
final Color accentColor = const Color(0xFF00B294);
final Color successColor = const Color(0xFF00C851);
final Color warningColor = const Color(0xFFE67E22);
final Color errorColor = const Color(0xFFE74C3C);

@override
void initState() {
super.initState();
_initializeAnimations();
_loadFavoriteRecipes();
_initGoogleSignIn();
}

void _initializeAnimations() {
_animationController = AnimationController(duration: const Duration(milliseconds: 800), vsync: this);
_headerAnimationController = AnimationController(duration: const Duration(milliseconds: 600), vsync: this);
_fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeInOut));
_scaleAnimation = Tween<double>(begin: 0.95, end: 1.0).animate(CurvedAnimation(parent: _animationController, curve: Curves.easeOut));
_headerSlideAnimation = Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero).animate(CurvedAnimation(parent: _headerAnimationController, curve: Curves.easeOut));
_headerAnimationController.forward();
_animationController.forward();
}

Future<void> _initGoogleSignIn() async {
try {
_googleUser = await _googleSignIn.signInSilently();
_googleUser ??= await _googleSignIn.signIn();
} catch (e) {
_logger.e('Lỗi khởi tạo Google Sign-In: $e');
_showErrorSnackBar('Lỗi khởi tạo Google Sign-In, vui lòng thử lại.', retryAction: _initGoogleSignIn);
}
}

Future<void> _loadFavoriteRecipes() async {
setState(() => _loading = true);
try {
final response = await _httpClient.get(Uri.parse('$_ngrokUrl/get_favorite_recipes?userId=${widget.userId}'));
if (response.statusCode == 200) {
final data = jsonDecode(response.body);
setState(() {
_favoriteRecipeIds = (data['recipes'] as List<dynamic>?)?.map((r) => r['recipeId'].toString()).toSet() ?? {};
_loading = false;
});
_logger.i('Đã tải ${_favoriteRecipeIds.length} công thức yêu thích');
} else {
_logger.w('Không thể tải công thức yêu thích: ${response.body}');
_showErrorSnackBar('Không thể tải công thức yêu thích.', retryAction: _loadFavoriteRecipes);
}
} catch (e) {
_logger.e('Lỗi tải công thức yêu thích: $e');
_showErrorSnackBar('Lỗi tải công thức yêu thích: $e', retryAction: _loadFavoriteRecipes);
} finally {
setState(() => _loading = false);
}
}

Future<void> _generateWeeklyMealPlan() async {
if (_loading) {
_logger.i('Generate meal plan already in progress, ignoring new request');
return;
}

setState(() => _loading = true);
try {
final response = await _httpClient.post(
Uri.parse('$_ngrokUrl/generate_weekly_meal_plan'),
headers: {'Content-Type': 'application/json'},
body: jsonEncode({
'targetCalories': _targetCalories ?? 2000,
'userId': widget.userId,
'diet': _selectedDiet,
'useFridgeIngredients': _useFridgeIngredients,
'timeFrame': _selectedTimeFrame,
}),
);

if (response.statusCode == 200) {
final data = jsonDecode(response.body);
final mealPlan = data['mealPlan'] as Map<String, dynamic>? ?? {};
_mealPlanId = data['mealPlanId'] as String?;

final processedWeek = mealPlan.map((day, dayData) {
final meals = (dayData['meals'] as List<dynamic>?)?.map((recipe) => {
'id': recipe['id']?.toString() ?? '',
'title': recipe['title'] ?? 'Không có tiêu đề',
'image': recipe['image']?.toString() ?? '',
'readyInMinutes': recipe['readyInMinutes'] ?? 'N/A',
'ingredientsUsed': (recipe['ingredientsUsed'] as List<dynamic>?)?.map((e) => e['name'].toString()).toList() ?? [],
'ingredientsMissing': (recipe['ingredientsMissing'] as List<dynamic>?)?.map((e) => e['name'].toString()).toList() ?? [],
'instructions': (recipe['instructions'] is List)
? (recipe['instructions'] as List).whereType<String>().join('\n')
    : recipe['instructions']?.toString() ?? 'Không có hướng dẫn',
'nutrients': (recipe['nutrition'] as List<dynamic>?)?.isNotEmpty == true
? (recipe['nutrition'] as List<dynamic>).fold<Map<String, String>>(
{'calories': 'N/A', 'carbohydrates': 'N/A', 'fat': 'N/A', 'protein': 'N/A'},
(acc, nutrient) => {
...acc,
if (nutrient['name'] == 'Calories') 'calories': nutrient['amount']?.toString() ?? 'N/A',
if (nutrient['name'] == 'Carbohydrates') 'carbohydrates': nutrient['amount']?.toString() ?? 'N/A',
if (nutrient['name'] == 'Fat') 'fat': nutrient['amount']?.toString() ?? 'N/A',
if (nutrient['name'] == 'Protein') 'protein': nutrient['amount']?.toString() ?? 'N/A',
})
    : {'calories': 'N/A', 'carbohydrates': 'N/A', 'fat': 'N/A', 'protein': 'N/A'},
'isFavorite': _favoriteRecipeIds.contains(recipe['id']?.toString()),
'timeSlot': recipe['timeSlot'] ?? 'unknown',
}).toList() ?? [];
meals.sort((a, b) => (int.tryParse(a['readyInMinutes'] ?? '0') ?? 0).compareTo(int.tryParse(b['readyInMinutes'] ?? '0') ?? 0));
_seenRecipeIds['week']!.addAll(meals.map((r) => r['id'].toString()));
return MapEntry(day, meals);
});

setState(() {
_mealPlan = {'week': processedWeek};
_loading = false;
});
_showSuccessSnackBar('Đã tạo kế hoạch ${_timeFrameTranslations[_selectedTimeFrame]} với ${mealPlan.values.fold<int>(0, (sum, e) => sum + (e['meals'] as List?)!.length)} công thức!');
} else if (response.statusCode == 429) {
_showErrorSnackBar('Hết quota API, vui lòng thử lại sau.', retryAction: _generateWeeklyMealPlan);
} else {
_showErrorSnackBar('Lỗi khi tạo kế hoạch: ${response.body}', retryAction: _generateWeeklyMealPlan);
}
} catch (e) {
_logger.e('Lỗi tạo kế hoạch: $e');
_showErrorSnackBar('Lỗi khi tạo kế hoạch: $e', retryAction: _generateWeeklyMealPlan);
} finally {
setState(() => _loading = false);
}
}

Future<void> _suggestFavoriteRecipes() async {
if (_loading) {
_logger.i('Suggest favorite recipes already in progress, ignoring new request');
return;
}

setState(() => _loading = true);
try {
final response = await _httpClient.post(
Uri.parse('$_ngrokUrl/suggest_favorite_recipes'),
headers: {'Content-Type': 'application/json'},
body: jsonEncode({'userId': widget.userId, 'favoriteRecipeIds': _favoriteRecipeIds.toList()}),
);
if (response.statusCode == 200) {
final data = jsonDecode(response.body);
final newMeals = (data['recipes'] as List<dynamic>).map((r) => {
'id': r['id']?.toString() ?? '',
'title': r['title'] ?? 'Không có tiêu đề',
'image': r['image']?.toString() ?? '',
'readyInMinutes': r['readyInMinutes'] ?? 'N/A',
'ingredientsUsed': (r['ingredientsUsed'] as List<dynamic>?)?.map((e) => e['name'].toString()).toList() ?? [],
'ingredientsMissing': (r['ingredientsMissing'] as List<dynamic>?)?.map((e) => e['name'].toString()).toList() ?? [],
'instructions': (r['instructions'] is List)
? (r['instructions'] as List).whereType<String>().join('\n')
    : r['instructions']?.toString() ?? 'Không có hướng dẫn',
'nutrients': r['nutrition'] ?? {'calories': 'N/A', 'carbohydrates': 'N/A', 'fat': 'N/A', 'protein': 'N/A'},
'isFavorite': true,
'timeSlot': 'Suggested',
}).toList();
setState(() {
_mealPlan = {'week': {'Suggested': newMeals}};
_loading = false;
});
_showSuccessSnackBar('Đã gợi ý ${newMeals.length} công thức dựa trên sở thích!');
} else {
_showErrorSnackBar('Lỗi khi gợi ý công thức: ${response.body}', retryAction: _suggestFavoriteRecipes);
}
} catch (e) {
_logger.e('Lỗi gợi ý công thức yêu thích: $e');
_showErrorSnackBar('Lỗi khi gợi ý công thức: $e', retryAction: _suggestFavoriteRecipes);
} finally {
setState(() => _loading = false);
}
}

Future<void> _syncMealPlanToCalendar() async {
if (_mealPlanId == null) {
_showErrorSnackBar('Vui lòng tạo kế hoạch tuần trước khi đồng bộ.');
return;
}

if (_loading) {
_logger.i('Sync already in progress, ignoring new request');
return;
}

if (_googleUser == null || await _googleSignIn.isSignedIn() == false) {
await showDialog(
context: context,
builder: (context) => AlertDialog(
backgroundColor: currentSurfaceColor,
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
title: Text(
'Yêu cầu đăng nhập Google',
style: TextStyle(color: currentTextPrimaryColor, fontWeight: FontWeight.bold),
),
content: Text(
'Bạn cần đăng nhập Google để đồng bộ kế hoạch bữa ăn với Google Calendar.',
style: TextStyle(color: currentTextSecondaryColor),
),
actions: [
TextButton(
onPressed: () => Navigator.pop(context),
child: Text('Hủy', style: TextStyle(color: primaryColor)),
),
TextButton(
onPressed: () async {
Navigator.pop(context);
_googleUser = await _googleSignIn.signIn();
if (_googleUser != null) {
await _syncMealPlanToCalendar();
}
},
child: Text('Đăng nhập', style: TextStyle(color: primaryColor)),
),
],
),
);
return;
}

setState(() => _loading = true);
try {
final authHeaders = await _googleUser!.authHeaders;
final accessToken = authHeaders['Authorization']?.replaceFirst('Bearer ', '');

final response = await _httpClient.post(
Uri.parse('$_ngrokUrl/sync_meal_plan_to_calendar'),
headers: {'Content-Type': 'application/json'},
body: jsonEncode({
'userId': widget.userId,
'mealPlanId': _mealPlanId,
'accessToken': accessToken,
}),
);

if (response.statusCode == 200) {
_showSuccessSnackBar('Đã đồng bộ kế hoạch tuần với Google Calendar!');
} else {
_showErrorSnackBar('Lỗi khi đồng bộ với Google Calendar: ${response.body}', retryAction: _syncMealPlanToCalendar);
}
} catch (e) {
_logger.e('Lỗi đồng bộ Google Calendar: $e');
_showErrorSnackBar('Lỗi khi đồng bộ Google Calendar: $e', retryAction: _syncMealPlanToCalendar);
} finally {
setState(() => _loading = false);
}
}

Future<void> _toggleFavorite(String recipeId, bool isFavorite) async {
setState(() => _loading = true);
try {
final url = isFavorite ? '$_ngrokUrl/delete_favorite_recipe' : '$_ngrokUrl/add_favorite_recipe';
final payload = isFavorite
? {'favorite_recipe_id': recipeId, 'userId': widget.userId}
    : {
'userId': widget.userId,
'recipeId': recipeId,
'title': (_mealPlan['week'] as Map<String, dynamic>?)?.values.expand((e) => e as List).firstWhere((r) => r['id'].toString() == recipeId, orElse: () => {})['title'] ?? 'Không có tiêu đề',
'imageUrl': (_mealPlan['week'] as Map<String, dynamic>?)?.values.expand((e) => e as List).firstWhere((r) => r['id'].toString() == recipeId, orElse: () => {})['image'] ?? '',
};
final response = await _httpClient.post(
Uri.parse(url),
headers: {'Content-Type': 'application/json'},
body: jsonEncode(payload),
);

if (response.statusCode == 200) {
setState(() {
if (isFavorite) {
_favoriteRecipeIds.remove(recipeId);
} else {
_favoriteRecipeIds.add(recipeId);
}
final meals = _mealPlan['week'] as Map<String, dynamic>?;
if (meals != null) {
for (var dayMeals in meals.values) {
final dayList = dayMeals as List<Map<String, dynamic>>;
final recipeIndex = dayList.indexWhere((r) => r['id'].toString() == recipeId);
if (recipeIndex != -1) dayList[recipeIndex]['isFavorite'] = !isFavorite;
}
}
});
_showSuccessSnackBar(isFavorite ? 'Đã xóa khỏi yêu thích!' : 'Đã thêm vào yêu thích!');
} else {
throw Exception('Lỗi khi ${isFavorite ? 'xóa' : 'thêm'} công thức yêu thích: ${response.body}');
}
} catch (e) {
_logger.e('Lỗi cập nhật công thức yêu thích: $e');
_showErrorSnackBar('Lỗi khi cập nhật công thức yêu thích: $e', retryAction: () => _toggleFavorite(recipeId, isFavorite));
} finally {
setState(() => _loading = false);
}
}

Future<void> _addToShoppingList(Map<String, dynamic> recipe) async {
setState(() => _loading = true);
try {
final missingIngredients = (recipe['ingredientsMissing'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
if (missingIngredients.isEmpty) {
_showSuccessSnackBar('Không có nguyên liệu nào cần thêm vào giỏ hàng.');
return;
}
final items = missingIngredients.map((ing) => {'name': ing, 'amount': 1, 'unit': ''}).toList();
final response = await _httpClient.post(
Uri.parse('$_ngrokUrl/place_order'),
headers: {'Content-Type': 'application/json'},
body: jsonEncode({'userId': widget.userId, 'items': items}),
);
if (response.statusCode == 200) {
_showSuccessSnackBar('Đã thêm ${items.length} nguyên liệu vào giỏ hàng!');
} else {
throw Exception('Lỗi khi thêm vào giỏ hàng: ${response.body}');
}
} catch (e) {
_logger.e('Lỗi thêm vào giỏ hàng: $e');
_showErrorSnackBar('Lỗi khi thêm vào giỏ hàng: $e', retryAction: () => _addToShoppingList(recipe));
} finally {
setState(() => _loading = false);
}
}

void _showRecipeDetails(Map<String, dynamic> recipe) {
final missingCount = (recipe['ingredientsMissing'] as List<dynamic>? ?? []).length;
if (missingCount > 3) {
_showErrorSnackBar('Cảnh báo: Thiếu $missingCount nguyên liệu!');
}

showModalBottomSheet(
context: context,
isScrollControlled: true,
backgroundColor: Colors.transparent,
builder: (context) => Container(
decoration: BoxDecoration(
color: currentSurfaceColor,
borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
),
child: DraggableScrollableSheet(
initialChildSize: 0.9,
minChildSize: 0.5,
maxChildSize: 0.95,
expand: false,
builder: (context, scrollController) => DefaultTabController(
length: 3,
child: Column(
children: [
Container(
width: 40,
height: 4,
margin: const EdgeInsets.symmetric(vertical: 8),
decoration: BoxDecoration(
color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[300],
borderRadius: BorderRadius.circular(2),
),
),
TabBar(
labelColor: primaryColor,
unselectedLabelColor: currentTextSecondaryColor,
indicatorColor: primaryColor,
tabs: const [
Tab(text: 'Tổng quan'),
Tab(text: 'Nguyên liệu'),
Tab(text: 'Hướng dẫn'),
],
),
Expanded(
child: TabBarView(
children: [
// Tab Tổng quan
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
recipe['title'] ?? 'Không có tiêu đề',
style: TextStyle(
fontSize: 24,
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
),
onPressed: () {
setState(() {
recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
});
_toggleFavorite(recipe['id'].toString(), !(recipe['isFavorite'] ?? false));
},
),
],
),
const SizedBox(height: 16),
if (recipe['image'] != null && recipe['image'].isNotEmpty)
ClipRRect(
borderRadius: BorderRadius.circular(16),
child: Image.network(
recipe['image'],
height: 200,
width: double.infinity,
fit: BoxFit.cover,
errorBuilder: (context, error, stackTrace) => Container(
height: 200,
color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
child: Icon(Icons.broken_image, size: 50, color: widget.isDarkMode ? Colors.grey[400] : Colors.grey[600]),
),
),
),
const SizedBox(height: 16),
Container(
padding: const EdgeInsets.all(12),
decoration: BoxDecoration(
color: primaryColor.withOpacity(0.1),
borderRadius: BorderRadius.circular(12),
),
child: Row(
children: [
Icon(Icons.access_time, color: primaryColor),
const SizedBox(width: 8),
Text(
'Thời gian: ${recipe['readyInMinutes'] ?? 'N/A'} phút',
style: TextStyle(fontSize: 16, color: primaryColor, fontWeight: FontWeight.w600),
),
],
),
),
const SizedBox(height: 16),
if (recipe['nutrients'] != null)
Container(
padding: const EdgeInsets.all(12),
decoration: BoxDecoration(
color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
borderRadius: BorderRadius.circular(12),
),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(
'Dinh dưỡng',
style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
),
const SizedBox(height: 8),
Text(
'Calo: ${recipe['nutrients']['calories'] ?? 'N/A'} kcal\n'
'Carb: ${recipe['nutrients']['carbohydrates'] ?? 'N/A'} g\n'
'Fat: ${recipe['nutrients']['fat'] ?? 'N/A'} g\n'
'Protein: ${recipe['nutrients']['protein'] ?? 'N/A'} g',
style: TextStyle(fontSize: 16, color: currentTextPrimaryColor),
),
],
),
),
],
),
),
// Tab Nguyên liệu
SingleChildScrollView(
controller: scrollController,
padding: const EdgeInsets.all(16),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
if (recipe['ingredientsUsed'] != null)
_buildIngredientSection(
'Nguyên liệu có sẵn',
(recipe['ingredientsUsed'] as List<dynamic>).map((e) => e.toString()).toList(),
successColor,
Icons.check_circle,
),
const SizedBox(height: 16),
if (recipe['ingredientsMissing'] != null)
_buildIngredientSection(
'Nguyên liệu còn thiếu',
(recipe['ingredientsMissing'] as List<dynamic>).map((e) => e.toString()).toList(),
warningColor,
Icons.shopping_cart,
),
const SizedBox(height: 16),
if ((recipe['ingredientsMissing'] as List<dynamic>? ?? []).isNotEmpty)
Container(
width: double.infinity,
decoration: BoxDecoration(
gradient: LinearGradient(colors: [accentColor, primaryColor]),
borderRadius: BorderRadius.circular(12),
),
child: ElevatedButton.icon(
onPressed: _loading ? null : () => _addToShoppingList(recipe),
icon: Icon(Icons.add_shopping_cart, color: Colors.white),
label: Text(
'Thêm vào giỏ hàng',
style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
),
style: ElevatedButton.styleFrom(
backgroundColor: Colors.transparent,
shadowColor: Colors.transparent,
padding: const EdgeInsets.symmetric(vertical: 12),
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
),
),
),
],
),
),
// Tab Hướng dẫn
SingleChildScrollView(
controller: scrollController,
padding: const EdgeInsets.all(16),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(
'Hướng dẫn',
style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
),
const SizedBox(height: 12),
Container(
padding: const EdgeInsets.all(12),
decoration: BoxDecoration(
color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[50],
borderRadius: BorderRadius.circular(12),
border: Border.all(color: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[200]!),
),
child: Text(
recipe['instructions'] ?? 'Không có hướng dẫn chi tiết',
style: TextStyle(fontSize: 16, color: currentTextPrimaryColor, height: 1.5),
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

Future<void> _resetAllRecipes() async {
setState(() {
_seenRecipeIds = {'week': []};
_mealPlan = {};
_mealPlanId = null;
});
await _generateWeeklyMealPlan();
}

Widget _buildIngredientSection(String title, List<String> ingredients, Color color, IconData icon) {
return Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Row(
children: [
Icon(icon, color: color, size: 20),
const SizedBox(width: 8),
Text(
title,
style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
),
],
),
const SizedBox(height: 12),
if (ingredients.isEmpty)
Container(
padding: const EdgeInsets.all(12),
decoration: BoxDecoration(
color: widget.isDarkMode ? Colors.grey[700] : Colors.grey[100],
borderRadius: BorderRadius.circular(8),
),
child: Text(
title.contains('có sẵn') ? 'Không có nguyên liệu có sẵn' : 'Không có nguyên liệu còn thiếu',
style: TextStyle(color: currentTextSecondaryColor),
),
)
else
...ingredients.asMap().entries.map((entry) => Container(
margin: const EdgeInsets.only(bottom: 8),
padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
decoration: BoxDecoration(
color: color.withOpacity(0.1),
borderRadius: BorderRadius.circular(8),
border: Border.all(color: color.withOpacity(0.3)),
),
child: Row(
children: [
Text(
'${entry.key + 1}. ',
style: TextStyle(color: currentTextPrimaryColor, fontWeight: FontWeight.w600),
),
Expanded(
child: Text(
entry.value,
style: TextStyle(color: currentTextPrimaryColor),
),
),
],
),
)),
],
);
}

void _showErrorSnackBar(String message, {VoidCallback? retryAction}) {
ScaffoldMessenger.of(context).showSnackBar(
SnackBar(
content: Row(
children: [
Icon(Icons.error_outline, color: Colors.white),
const SizedBox(width: 8),
Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
],
),
backgroundColor: errorColor,
behavior: SnackBarBehavior.floating,
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
margin: const EdgeInsets.all(16),
action: retryAction != null
? SnackBarAction(
label: 'Thử lại',
textColor: Colors.white,
onPressed: retryAction,
)
    : null,
duration: const Duration(seconds: 5),
),
);
}

void _showSuccessSnackBar(String message) {
ScaffoldMessenger.of(context).showSnackBar(
SnackBar(
content: Row(
children: [
Icon(Icons.check_circle_outline, color: Colors.white),
const SizedBox(width: 8),
Expanded(child: Text(message, style: const TextStyle(color: Colors.white))),
],
),
backgroundColor: successColor,
behavior: SnackBarBehavior.floating,
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
margin: const EdgeInsets.all(16),
duration: const Duration(seconds: 3),
),
);
}

Widget _buildShimmerLoading() {
return Shimmer.fromColors(
baseColor: widget.isDarkMode ? Colors.grey[800]! : Colors.grey[200]!,
highlightColor: widget.isDarkMode ? Colors.grey[700]! : Colors.grey[100]!,
child: GridView.builder(
physics: const NeverScrollableScrollPhysics(),
shrinkWrap: true,
gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
crossAxisCount: 2,
crossAxisSpacing: 12,
mainAxisSpacing: 12,
childAspectRatio: 0.75,
),
itemCount: 6,
itemBuilder: (context, index) {
return Container(
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
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Container(
height: 120,
decoration: BoxDecoration(
color: Colors.grey[300],
borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
),
),
Padding(
padding: const EdgeInsets.all(8.0),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Container(height: 16, width: double.infinity, color: Colors.grey[300]),
const SizedBox(height: 8),
Container(height: 12, width: 100, color: Colors.grey[300]),
],
),
),
],
),
);
},
),
);
}

Widget _buildRecipeTile(Map<String, dynamic> recipe) {
if (recipe.isEmpty || recipe['title'] == null || recipe['id'] == null) {
_logger.w('Công thức không hợp lệ, bỏ qua: $recipe');
return const SizedBox.shrink();
}
return InkWell(
onTap: () => _showRecipeDetails(recipe),
borderRadius: BorderRadius.circular(16),
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
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Stack(
children: [
ClipRRect(
borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
child: recipe['image'] != null && recipe['image'].isNotEmpty
? Image.network(
recipe['image'],
height: 120,
width: double.infinity,
fit: BoxFit.cover,
errorBuilder: (context, error, stackTrace) => Container(
height: 120,
color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
child: Icon(Icons.restaurant, color: primaryColor),
),
)
    : Container(
height: 120,
color: widget.isDarkMode ? Colors.grey[800] : Colors.grey[200],
child: Icon(Icons.restaurant, color: primaryColor),
),
),
Positioned(
top: 8,
right: 8,
child: IconButton(
icon: Icon(
recipe['isFavorite'] ?? false ? Icons.favorite : Icons.favorite_border,
color: recipe['isFavorite'] ?? false ? errorColor : Colors.white.withOpacity(0.8),
),
onPressed: () {
_logger.i('Nhấn nút yêu thích, recipeId: ${recipe['id']}, isFavorite: ${recipe['isFavorite']}');
setState(() {
recipe['isFavorite'] = !(recipe['isFavorite'] ?? false);
});
_toggleFavorite(recipe['id'].toString(), !(recipe['isFavorite'] ?? false));
},
),
),
],
),
Padding(
padding: const EdgeInsets.all(12.0),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(
recipe['title'] ?? 'Không có tiêu đề',
style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
maxLines: 2,
overflow: TextOverflow.ellipsis,
),
const SizedBox(height: 4),
Row(
children: [
Icon(Icons.access_time, size: 16, color: currentTextSecondaryColor),
const SizedBox(width: 4),
Text(
'${recipe['readyInMinutes'] ?? 'N/A'} phút',
style: TextStyle(color: currentTextSecondaryColor),
),
const SizedBox(width: 8),
if (recipe['timeSlot'] != null && recipe['timeSlot'] != 'unknown')
Container(
padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
decoration: BoxDecoration(
color: primaryColor.withOpacity(0.1),
borderRadius: BorderRadius.circular(8),
),
child: Text(
recipe['timeSlot'],
style: TextStyle(fontSize: 12, color: primaryColor),
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
);
}

Widget _buildModernCard({required String title, required IconData icon, required Widget child}) {
return AnimatedBuilder(
animation: _fadeAnimation,
builder: (context, _) {
return Transform.scale(
scale: _scaleAnimation.value,
child: Opacity(
opacity: _fadeAnimation.value,
child: Container(
margin: const EdgeInsets.only(bottom: 16),
decoration: BoxDecoration(
color: currentSurfaceColor,
borderRadius: BorderRadius.circular(20),
boxShadow: [
BoxShadow(
color: Colors.black.withOpacity(widget.isDarkMode ? 0.3 : 0.05),
blurRadius: 15,
offset: const Offset(0, 5),
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
padding: const EdgeInsets.all(8),
decoration: BoxDecoration(
gradient: LinearGradient(colors: [primaryColor.withOpacity(0.2), primaryColor.withOpacity(0.1)]),
borderRadius: BorderRadius.circular(12),
),
child: Icon(icon, color: primaryColor, size: 20),
),
const SizedBox(width: 12),
Text(
title,
style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
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

@override
Widget build(BuildContext context) {
return Scaffold(
backgroundColor: currentBackgroundColor,
appBar: AppBar(
backgroundColor: Colors.transparent,
elevation: 0,
leading: IconButton(
icon: Icon(Icons.arrow_back_ios, color: currentTextPrimaryColor),
onPressed: () => Navigator.pop(context),
tooltip: 'Quay lại',
),
title: SlideTransition(
position: _headerSlideAnimation,
child: Text(
'Kế Hoạch Bữa Ăn',
style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
),
),
actions: [
IconButton(
icon: Icon(Icons.refresh, color: primaryColor),
tooltip: 'Làm mới kế hoạch',
onPressed: _loading ? null : _resetAllRecipes,
),
],
),
body: SafeArea(
child: _loading
? Column(
mainAxisAlignment: MainAxisAlignment.center,
children: [
const CircularProgressIndicator(),
const SizedBox(height: 16),
Text(
'Đang tải kế hoạch bữa ăn...',
style: TextStyle(color: currentTextPrimaryColor),
),
],
)
    : FadeTransition(
opacity: _fadeAnimation,
child: CustomScrollView(
slivers: [
SliverToBoxAdapter(
child: Padding(
padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
child: _buildModernCard(
title: 'Tùy Chọn Kế Hoạch',
icon: Icons.tune,
child: ExpansionTile(
title: Text(
'Cài đặt kế hoạch',
style: TextStyle(fontWeight: FontWeight.w600, color: currentTextPrimaryColor),
),
collapsedBackgroundColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[100],
backgroundColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[100],
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
children: [
Padding(
padding: const EdgeInsets.all(12.0),
child: Column(
children: [
DropdownButtonFormField<String>(
value: _selectedTimeFrame,
decoration: InputDecoration(
labelText: 'Khoảng thời gian',
labelStyle: TextStyle(color: currentTextSecondaryColor),
filled: true,
fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[100],
border: OutlineInputBorder(
borderRadius: BorderRadius.circular(12),
borderSide: BorderSide.none,
),
contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
),
items: _timeFrames.map((String timeFrame) {
return DropdownMenuItem<String>(
value: timeFrame,
child: Text(
_timeFrameTranslations[timeFrame]!,
style: TextStyle(color: currentTextPrimaryColor),
),
);
}).toList(),
onChanged: (String? newValue) {
setState(() {
_selectedTimeFrame = newValue ?? 'week';
});
},
dropdownColor: currentSurfaceColor,
icon: Icon(Icons.arrow_drop_down, color: primaryColor),
),
const SizedBox(height: 12),
DropdownButtonFormField<String>(
value: _selectedDiet,
decoration: InputDecoration(
labelText: 'Chế độ ăn',
labelStyle: TextStyle(color: currentTextSecondaryColor),
filled: true,
fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[100],
border: OutlineInputBorder(
borderRadius: BorderRadius.circular(12),
borderSide: BorderSide.none,
),
contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
),
items: [
const DropdownMenuItem<String>(
value: null,
child: Text('Không chọn', style: TextStyle(color: Colors.grey)),
),
..._diets.map((String diet) {
return DropdownMenuItem<String>(
value: diet,
child: Text(diet, style: TextStyle(color: currentTextPrimaryColor)),
);
}),
],
onChanged: (String? newValue) {
setState(() {
_selectedDiet = newValue;
});
},
dropdownColor: currentSurfaceColor,
icon: Icon(Icons.arrow_drop_down, color: primaryColor),
),
const SizedBox(height: 12),
TextField(
decoration: InputDecoration(
labelText: 'Calo mục tiêu (mặc định: 2000)',
labelStyle: TextStyle(color: currentTextSecondaryColor),
filled: true,
fillColor: widget.isDarkMode ? Colors.grey[800] : Colors.grey[100],
border: OutlineInputBorder(
borderRadius: BorderRadius.circular(12),
borderSide: BorderSide.none,
),
contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
),
keyboardType: TextInputType.number,
onChanged: (value) {
_targetCalories = int.tryParse(value) ?? 2000;
},
),
const SizedBox(height: 12),
CheckboxListTile(
title: Text(
'Tận dụng nguyên liệu từ tủ lạnh',
style: TextStyle(color: currentTextPrimaryColor),
),
value: _useFridgeIngredients,
onChanged: (bool? value) {
setState(() {
_useFridgeIngredients = value ?? false;
});
},
activeColor: primaryColor,
checkColor: Colors.white,
contentPadding: const EdgeInsets.symmetric(horizontal: 0),
),
],
),
),
],
),
),
),
),
SliverToBoxAdapter(
child: Padding(
padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
child: Row(
children: [
Expanded(
child: Container(
decoration: BoxDecoration(
gradient: LinearGradient(colors: [primaryColor, accentColor]),
borderRadius: BorderRadius.circular(12),
boxShadow: [
BoxShadow(color: primaryColor.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4)),
],
),
child: ElevatedButton.icon(
onPressed: _loading ? null : _generateWeeklyMealPlan,
icon: Icon(Icons.create, color: Colors.white),
label: Text(
'Tạo Kế Hoạch',
style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
),
style: ElevatedButton.styleFrom(
backgroundColor: Colors.transparent,
shadowColor: Colors.transparent,
padding: const EdgeInsets.symmetric(vertical: 12),
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
),
),
),
),
if (_favoriteRecipeIds.isNotEmpty) const SizedBox(width: 12),
if (_favoriteRecipeIds.isNotEmpty)
Expanded(
child: Container(
decoration: BoxDecoration(
gradient: LinearGradient(colors: [accentColor, primaryColor]),
borderRadius: BorderRadius.circular(12),
boxShadow: [
BoxShadow(color: accentColor.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4)),
],
),
child: ElevatedButton.icon(
onPressed: _loading ? null : _suggestFavoriteRecipes,
icon: Icon(Icons.lightbulb, color: Colors.white),
label: Text(
'Gợi ý yêu thích',
style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
),
style: ElevatedButton.styleFrom(
backgroundColor: Colors.transparent,
shadowColor: Colors.transparent,
padding: const EdgeInsets.symmetric(vertical: 12),
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
),
),
),
),
],
),
),
),
if (_mealPlanId != null)
SliverToBoxAdapter(
child: Padding(
padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
child: Container(
decoration: BoxDecoration(
gradient: LinearGradient(colors: [accentColor, primaryColor]),
borderRadius: BorderRadius.circular(12),
boxShadow: [
BoxShadow(color: accentColor.withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 4)),
],
),
child: ElevatedButton.icon(
onPressed: _loading ? null : _syncMealPlanToCalendar,
icon: Icon(Icons.sync, color: Colors.white),
label: Text(
'Đồng bộ Google Calendar',
style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
),
style: ElevatedButton.styleFrom(
backgroundColor: Colors.transparent,
shadowColor: Colors.transparent,
padding: const EdgeInsets.symmetric(vertical: 12),
shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
),
),
),
),
),
if (_mealPlan.isNotEmpty)
SliverToBoxAdapter(
child: Padding(
padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
child: _buildModernCard(
title: 'Kế Hoạch Bữa Ăn',
icon: Icons.restaurant_menu,
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(
'Tổng cộng: ${(_mealPlan['week'] as Map<String, dynamic>?)?.values.fold<int>(0, (sum, e) => sum + (e as List?)!.length) ?? 0} công thức',
style: TextStyle(fontSize: 14, color: currentTextSecondaryColor),
),
const SizedBox(height: 16),
...(_mealPlan['week'] != null
? (Map<String, dynamic>.from(_mealPlan['week'] as Map).entries)
    : <MapEntry<String, dynamic>>[]).map((entry) {
final day = entry.key;
final meals = (entry.value as List<dynamic>? ?? []).toList();
return Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(
_timeFrameTranslations[day] ?? day,
style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: currentTextPrimaryColor),
),
const SizedBox(height: 12),
GridView.builder(
physics: const NeverScrollableScrollPhysics(),
shrinkWrap: true,
gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
crossAxisCount: 2,
crossAxisSpacing: 12,
mainAxisSpacing: 12,
childAspectRatio: 0.75,
),
itemCount: meals.length,
itemBuilder: (context, index) => _buildRecipeTile(meals[index] as Map<String, dynamic>),
),
],
);
}),
],
),
),
),
),
SliverToBoxAdapter(child: const SizedBox(height: 80)),
],
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
_googleSignIn.disconnect();
super.dispose();
}
}
