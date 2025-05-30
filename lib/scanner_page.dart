import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:vibration/vibration.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:genexyz_scanner/constants/app_colors.dart';
import 'dart:math' as math;

class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  State<QRScannerPage> createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final MobileScannerController controller = MobileScannerController();
  bool isDialogShowing = false;
  bool isTorchOn = false;
  bool showInvalidQRWarning = false;
  Timer? _warningTimer;
  bool isScannerActive = true; // This will control whether to process scans
  bool isSending = false;
  bool isSuccess = false;
  bool isFailed = false;
  
  // Settings variables with default values
  String columnStart = "C"; // Default column (F)
  int rowStart = 4;         // Default row start
  String cipherKey = "G";   // Default cipher key
  int timeSlotColumnSpacing = 6; // Default time slot column spacing
  int timeSlotTicketCount = 150; // Default time slot ticket count
  bool manualCheckingMode = false; // Default manual checking mode
  
  // PIN attempt tracking
  int pinAttempts = 0;
  bool showSettingsButton = true;

  final GlobalKey _boxKey = GlobalKey();
  
  @override
  void initState() {
    super.initState();
    _loadSettings();
  }
  
  // Load settings from SharedPreferences
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        columnStart = prefs.getString('columnStart') ?? 'C';
        rowStart = prefs.getInt('rowStart') ?? 4;
        cipherKey = prefs.getString('cipherKey') ?? 'G';
        timeSlotColumnSpacing = prefs.getInt('timeSlotColumnSpacing') ?? 6;
        timeSlotTicketCount = prefs.getInt('timeSlotTicketCount') ?? 150;
        manualCheckingMode = prefs.getBool('manualCheckingMode') ?? false;
        
        // Load PIN attempts
        pinAttempts = prefs.getInt('pinAttempts') ?? 0;
        showSettingsButton = pinAttempts < 3;
      });
    } catch (e) {
      print('Error loading settings: $e');
    }
  }
  
  // Save settings to SharedPreferences
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('columnStart', columnStart);
      await prefs.setInt('rowStart', rowStart);
      await prefs.setString('cipherKey', cipherKey);
      await prefs.setInt('timeSlotColumnSpacing', timeSlotColumnSpacing);
      await prefs.setInt('timeSlotTicketCount', timeSlotTicketCount);
      await prefs.setBool('manualCheckingMode', manualCheckingMode);
      
      // Save PIN attempts
      await prefs.setInt('pinAttempts', pinAttempts);
    } catch (e) {
      print('Error saving settings: $e');
    }
  }
  
  // Convert column letter to number (A=1, B=2, etc.)
  int _columnLetterToNumber(String letter) {
    if (letter.isEmpty) return 0;
    return letter.toUpperCase().codeUnitAt(0) - 64; // 'A' is 65 in ASCII, so A=1, B=2, etc.
  }

  String decryptCaesarHex(String hex, String key) {
    int shift = key.codeUnitAt(0);
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      int val = int.parse(hex.substring(i, i + 2), radix: 16);
      int original = (val - shift) % 256;
      if (original < 0) original += 256;
      bytes.add(original);
    }
    return String.fromCharCodes(bytes);
  }

  @override
  void dispose() {
    _warningTimer?.cancel();
    controller.dispose();
    super.dispose();
  }

  Future<bool> sendDataToSheet({
    required int row,
    required int col,
    String value = '✅',
    String sheetName = 'Sheet1',
  }) async {
    final url = Uri.parse('https://script.google.com/macros/s/AKfycbwfZ-AbmRPruwQY6KBK-zttEWMrUauup-sKFXykpwnYn46vOjP3GwIDJwmAyVwSi-v5bw/exec');

    try {
      final response = await http.post(
        url,
        body: {
          'row': row.toString(),
          'col': col.toString(),
          'value': value,
          'sheetName': sheetName.toString(),
        },
      );

      if (response.statusCode == 200 || response.statusCode == 302) {
        print('Sheet update success: ${response.body}');
        return true;
      } else {
        print('Sheet update failed: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      print('Error hitting sheet endpoint: $e');
      return false;
    }
  }

  Future<List<dynamic>> isCellChecked(int row, int col, String sheetName) async {
    try {
      final url = Uri.parse(
        'https://script.google.com/macros/s/AKfycbwfZ-AbmRPruwQY6KBK-zttEWMrUauup-sKFXykpwnYn46vOjP3GwIDJwmAyVwSi-v5bw/exec?row=$row&col=$col&sheetName=$sheetName',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final body = response.body.trim();

        final data = body.split('/');

        return [data[0] == 'Checked', data[1] == 'Checked', data[2]];
      } else {
        return [false, false, 'error'];
      }
    } catch (e) {
      print('Error hitting sheet endpoint: $e');
      return [false, false, 'error'];
    }
  }
  
  // Show settings dialog
  void _showSettingsDialog() {
    // Show PIN dialog first
    _showPinDialog();
  }

  // Show PIN verification dialog
  void _showPinDialog() {
    setState(() {
      isDialogShowing = true;
      isScannerActive = false; // Disable scanning but keep widget mounted
    });
    
    // PIN entry state
    String enteredPin = "";
    final correctPin = dotenv.env['PIN'];
    bool showError = false;
    bool showMaxAttemptsWarning = pinAttempts >= 3;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async {
          // Prevent dismissal with back button
          setState(() {
            isDialogShowing = false;
            isScannerActive = true;
          });
          return false;
        },
        child: StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
            backgroundColor: AppColors.backgroundLight,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 450),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final boxWidth = constraints.maxWidth;
                  
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Text(
                          showMaxAttemptsWarning ? 'Warning' : 'Enter PIN',
                          style: TextStyle(
                            fontSize: boxWidth * 0.085,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryLight,
                          ),
                        ),
                        
                        const SizedBox(height: 16),
                        
                        // PIN display field
                        if (!showMaxAttemptsWarning)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: showError ? Colors.red : AppColors.primaryLight.withOpacity(0.5),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            enteredPin.isEmpty ? 'Enter PIN' : 
                            enteredPin.replaceAll(RegExp(r'.'), '•'),
                            style: TextStyle(
                              fontSize: boxWidth * 0.05,
                              color: enteredPin.isEmpty ? Colors.grey : AppColors.primaryLight,
                            ),
                          ),
                        ),
                        
                        if (showError && !showMaxAttemptsWarning)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Invalid PIN. Please try again. (${3 - pinAttempts} attempts remaining)',
                              style: TextStyle(
                                color: Colors.red,
                                fontSize: boxWidth * 0.035,
                              ),
                            ),
                          ),
                        
                        if (showMaxAttemptsWarning)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.shade300),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.warning_amber_rounded, color: Colors.red, size: boxWidth * 0.06),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Maximum attempts reached',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.red,
                                          fontSize: boxWidth * 0.04,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Settings access has been disabled.',
                                  style: TextStyle(
                                    color: Colors.red.shade700,
                                    fontSize: boxWidth * 0.035,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        
                        const SizedBox(height: 20),
                        
                        // PIN keyboard
                        if (!showMaxAttemptsWarning)
                          GridView.count(
                            physics: const NeverScrollableScrollPhysics(),
                            shrinkWrap: true,
                            crossAxisCount: 3,
                            childAspectRatio: 1,
                            mainAxisSpacing: boxWidth * 0.045,
                            crossAxisSpacing: boxWidth * 0.045,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            children: [
                              // Numbers 1-9
                              for (int i = 1; i <= 9; i++)
                                _buildPinButton(
                                  i.toString(),
                                  () {
                                    setDialogState(() {
                                      enteredPin += i.toString();
                                      showError = false;
                                    });
                                  },
                                  color: AppColors.backgroundLight,
                                  boxWidth: boxWidth,
                                ),
                              // Clear button
                              _buildPinButton(
                                'C',
                                () {
                                  setDialogState(() {
                                    if (enteredPin.isNotEmpty) {
                                      enteredPin = '';
                                    }
                                    showError = false;
                                  });
                                },
                                color: Colors.red,
                                boxWidth: boxWidth,
                                borderColor: Colors.red,
                              ),
                              // Number 0
                              _buildPinButton(
                                '0',
                                () {
                                  setDialogState(() {
                                    enteredPin += '0';
                                    showError = false;
                                  });
                                },
                                color: AppColors.backgroundLight,
                                boxWidth: boxWidth,
                              ),
                              // # button
                              _buildPinButton(
                                '#',
                                () {
                                  setDialogState(() {
                                    enteredPin += '#';
                                    showError = false;
                                  });
                                },
                                color: Colors.blue,
                                boxWidth: boxWidth,
                                borderColor: Colors.blue,
                              ),
                            ],
                          ),
                        
                        const SizedBox(height: 25),
                        
                        // Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Cancel button
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  setState(() {
                                    isDialogShowing = false;
                                    isScannerActive = true; // Reactivate scanner when closing dialog
                                  });
                                },
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.blue,
                                  side: const BorderSide(color: Colors.blue),
                                  padding: const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                ),
                                child: Text(
                                  showMaxAttemptsWarning ? 'Close' : 'Cancel',
                                  style: TextStyle(
                                    fontSize: boxWidth * 0.055,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            
                            if (!showMaxAttemptsWarning) ...[
                              const SizedBox(width: 12),
                              
                              // Verify button
                              Expanded(
                                child: TextButton(
                                  onPressed: () {
                                    if (enteredPin == correctPin) {
                                      Navigator.of(context).pop();
                                      _showSettingsModalDialog();
                                      // Reset attempts on successful login
                                      setState(() {
                                        pinAttempts = 0;
                                        showSettingsButton = true;
                                      });
                                      _saveSettings(); // Save the reset attempts
                                    } else {
                                      setState(() {
                                        pinAttempts++;
                                      });
                                      _saveSettings(); // Save the updated attempts
                                      
                                      if (pinAttempts >= 3) {
                                        setState(() {
                                          showSettingsButton = false;
                                        });
                                        Navigator.of(context).pop();
                                        _showPinDialog(); // Show the dialog again with max attempts warning
                                      } else {
                                        setDialogState(() {
                                          showError = true;
                                          enteredPin = "";
                                        });
                                      }
                                    }
                                  },
                                  style: TextButton.styleFrom(
                                    backgroundColor: Colors.blue,
                                    foregroundColor: AppColors.backgroundLight,
                                    padding: const EdgeInsets.symmetric(vertical: 16),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(32),
                                    ),
                                  ),
                                  child: Text(
                                    'Verify',
                                    style: TextStyle(
                                      fontSize: boxWidth * 0.055,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  );
                }
              ),
            ),
          ),
        ),
      ),
    );
  }
  
  // Helper method to build PIN keyboard buttons
  Widget _buildPinButton(String text, VoidCallback onPressed, {required Color color, required double boxWidth, Color? borderColor}) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: color.withOpacity(0.1),
        foregroundColor: AppColors.primaryLight,
        shape: CircleBorder(),
        side: BorderSide(
          color: borderColor != null ? borderColor.withOpacity(0.25) : AppColors.primaryLight.withOpacity(0.5),
          width: 1.5,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: boxWidth * 0.065,
          fontWeight: FontWeight.bold,
          color: AppColors.primaryLight,
        ),
      ),
    );
  }
  
  // The actual settings modal dialog
  void _showSettingsModalDialog() {
    setState(() {
      isDialogShowing = true;
      isScannerActive = false; // Disable scanning but keep widget mounted
    });
    
    // Controllers for text fields
    final columnController = TextEditingController(text: columnStart);
    final rowController = TextEditingController(text: rowStart.toString());
    final cipherController = TextEditingController(text: cipherKey);
    final timeSlotColumnSpacingController = TextEditingController(text: timeSlotColumnSpacing.toString());
    final timeSlotTicketCountController = TextEditingController(text: timeSlotTicketCount.toString());
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async {
          // Prevent dismissal with back button
          setState(() {
            isDialogShowing = false;
            isScannerActive = true;
          });
          return false;
        },
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          backgroundColor: AppColors.backgroundLight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 450),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final boxWidth = constraints.maxWidth;
                
                return Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Header
                      Text(
                        'Scanner Settings',
                        style: TextStyle(
                          fontSize: boxWidth * 0.085,
                          fontWeight: FontWeight.bold,
                          color: AppColors.primaryLight,
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // Scrollable content
                      Container(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.of(context).size.height * 0.6, // Limit height to 40% of screen
                        ),
                        child: SingleChildScrollView(
                          physics: ClampingScrollPhysics(),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Column and Row settings in a row
                              Row(
                                children: [
                                  // Column setting
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Column Start',
                                          style: TextStyle(
                                            color: AppColors.primaryLight.withOpacity(0.75),
                                            fontSize: boxWidth * 0.05,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: columnController,
                                          decoration: InputDecoration(
                                            hintText: 'Enter a letter (e.g. F)',
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(32),
                                            ),
                                            contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                            counterStyle: TextStyle(
                                              color: AppColors.primaryLight,
                                            ),
                                          ),
                                          maxLength: 1,
                                          style: TextStyle(
                                            fontSize: boxWidth * 0.05,
                                            color: AppColors.primaryLight,
                                          ),
                                          textCapitalization: TextCapitalization.characters,
                                          onChanged: (value) {
                                            // Only allow alphabetic characters
                                            if (value.isNotEmpty && !RegExp(r'^[a-zA-Z]$').hasMatch(value)) {
                                              columnController.text = columnStart;
                                              columnController.selection = TextSelection.fromPosition(
                                                TextPosition(offset: columnController.text.length)
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  
                                  const SizedBox(width: 20),
                                  
                                  // Row setting
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Row Start',
                                          style: TextStyle(
                                            color: AppColors.primaryLight.withOpacity(0.75),
                                            fontSize: boxWidth * 0.05,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        TextField(
                                          controller: rowController,
                                          decoration: InputDecoration(
                                            hintText: 'Enter a number (e.g. 2)',
                                            border: OutlineInputBorder(
                                              borderRadius: BorderRadius.circular(32),
                                            ),
                                            contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                            counterStyle: TextStyle(
                                              color: AppColors.primaryLight,
                                            ),
                                          ),
                                          style: TextStyle(
                                            fontSize: boxWidth * 0.05,
                                            color: AppColors.primaryLight,
                                          ),
                                          keyboardType: TextInputType.number,
                                          maxLength: 2,
                                          onChanged: (value) {
                                            // Only allow numeric characters
                                            if (value.isNotEmpty && !RegExp(r'^[0-9]+$').hasMatch(value)) {
                                              rowController.text = rowStart.toString();
                                              rowController.selection = TextSelection.fromPosition(
                                                TextPosition(offset: rowController.text.length)
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              
                              const SizedBox(height: 4),
                              
                              // Cipher key setting
                              Text(
                                'Cipher Key',
                                style: TextStyle(
                                  color: AppColors.primaryLight.withOpacity(0.75),
                                  fontSize: boxWidth * 0.05,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: cipherController,
                                decoration: InputDecoration(
                                  hintText: 'Enter a letter (e.g. G)',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                  contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                  counterStyle: TextStyle(
                                    color: AppColors.primaryLight,
                                  ),
                                ),
                                maxLength: 1,
                                style: TextStyle(
                                  fontSize: boxWidth * 0.05,
                                  color: AppColors.primaryLight,
                                ),
                                textCapitalization: TextCapitalization.characters,
                                onChanged: (value) {
                                  // Only allow alphabetic characters
                                  if (value.isNotEmpty && !RegExp(r'^[a-zA-Z]$').hasMatch(value)) {
                                    cipherController.text = cipherKey;
                                    cipherController.selection = TextSelection.fromPosition(
                                      TextPosition(offset: cipherController.text.length)
                                    );
                                  }
                                },
                              ),

                              const SizedBox(height: 4),

                              Text(
                                'Column Spacing',
                                style: TextStyle(
                                  color: AppColors.primaryLight.withOpacity(0.75),
                                  fontSize: boxWidth * 0.05,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: timeSlotColumnSpacingController,
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  hintText: 'Enter a number (e.g. 10)',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                  contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                  counterStyle: TextStyle(
                                    color: AppColors.primaryLight,
                                  ),
                                ),
                                maxLength: 2,
                                style: TextStyle(
                                  fontSize: boxWidth * 0.05,
                                  color: AppColors.primaryLight,
                                ),
                                textCapitalization: TextCapitalization.characters,
                                onChanged: (value) {
                                  // Only allow numeric characters
                                  if (value.isNotEmpty && !RegExp(r'^[0-9]+$').hasMatch(value)) {
                                    timeSlotColumnSpacingController.text = timeSlotColumnSpacing.toString();
                                    timeSlotColumnSpacingController.selection = TextSelection.fromPosition(
                                      TextPosition(offset: timeSlotColumnSpacingController.text.length)
                                    );
                                  }
                                },
                              ),

                              const SizedBox(height: 4),

                              Text(
                                'Time Slot Ticket Count',
                                style: TextStyle(
                                  color: AppColors.primaryLight.withOpacity(0.75),
                                  fontSize: boxWidth * 0.05,
                                ),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: timeSlotTicketCountController,  
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  hintText: 'Enter a number (e.g. 10)',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                  contentPadding: EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                                  counterStyle: TextStyle(
                                    color: AppColors.primaryLight,
                                  ),
                                ),
                                maxLength: 4,
                                style: TextStyle(
                                  fontSize: boxWidth * 0.05,
                                  color: AppColors.primaryLight,
                                ),
                                textCapitalization: TextCapitalization.characters,
                                onChanged: (value) {
                                  // Only allow alphabetic characters
                                  if (value.isNotEmpty && !RegExp(r'^[0-9]+$').hasMatch(value)) {
                                    timeSlotTicketCountController.text = timeSlotTicketCount.toString();
                                    timeSlotTicketCountController.selection = TextSelection.fromPosition(
                                      TextPosition(offset: timeSlotTicketCountController.text.length)
                                    );
                                  }
                                },
                              ),
                              
                              const SizedBox(height: 10),
                              
                              // Manual Checking Mode toggle
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Bypass Warnings',
                                    style: TextStyle(
                                      fontSize: boxWidth * 0.05,
                                      color: AppColors.primaryLight,
                                    ),
                                  ),
                                  StatefulBuilder(
                                    builder: (BuildContext context, StateSetter setDialogState) {
                                      return Switch(
                                        value: manualCheckingMode,
                                        onChanged: (bool value) {
                                          setDialogState(() {
                                            manualCheckingMode = value;
                                          });
                                          setState(() {
                                            manualCheckingMode = value;
                                          });
                                        },
                                        activeColor: Colors.blue,
                                        inactiveTrackColor: Colors.transparent,
                                        inactiveThumbColor: Colors.grey,
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // Buttons - outside of the scrollable area
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Cancel button
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () {
                                Navigator.of(context).pop();
                                setState(() {
                                  isDialogShowing = false;
                                  isScannerActive = true; // Reactivate scanner when closing dialog
                                });
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.blue,
                                side: const BorderSide(color: Colors.blue),
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(32),
                                ),
                              ),
                              child: Text(
                                'Cancel',
                                style: TextStyle(
                                  fontSize: boxWidth * 0.055,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                          
                          const SizedBox(width: 12),
                          
                          // Save button
                          Expanded(
                            child: TextButton(
                              onPressed: () {
                                // Validate input
                                if (columnController.text.isEmpty ||
                                    rowController.text.isEmpty ||
                                    cipherController.text.isEmpty ||
                                    timeSlotColumnSpacingController.text.isEmpty ||
                                    timeSlotTicketCountController.text.isEmpty) {
                                  // Show validation error
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Please fill all fields'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                  return;
                                }
                                
                                // Update state with new values
                                setState(() {
                                  columnStart = columnController.text.toUpperCase();
                                  rowStart = int.parse(rowController.text);
                                  cipherKey = cipherController.text.toUpperCase();
                                  timeSlotColumnSpacing = int.parse(timeSlotColumnSpacingController.text);
                                  timeSlotTicketCount = int.parse(timeSlotTicketCountController.text);
                                });
                                
                                // Save to shared preferences
                                _saveSettings();
                                
                                // Close dialog
                                Navigator.of(context).pop();
                                setState(() {
                                  isDialogShowing = false;
                                  isScannerActive = true; // Reactivate scanner when closing dialog
                                });
                              },
                              style: TextButton.styleFrom(
                                backgroundColor: Colors.blue,
                                foregroundColor: AppColors.backgroundLight,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(32),
                                ),
                              ),
                              child: Text(
                                'Save',
                                style: TextStyle(
                                  fontSize: boxWidth * 0.055,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Full screen scanner - always show but only process when active
          MobileScanner(
            controller: controller,
            onDetect: (capture) {
              // Only process scans when scanner is active
              if (isScannerActive && !isDialogShowing) {
                // Get the screen size to calculate the scan area
                final screenSize = MediaQuery.of(context).size;
                // Frame is positioned in center with fixed size 250x250
                final frameSize = (screenSize.width * 0.6);
                final frameLeft = (screenSize.width - frameSize) / 2;
                final frameTop = (screenSize.height - frameSize) / 2;
                final frameRight = frameLeft + frameSize;
                final frameBottom = frameTop + frameSize;
                
                // The capture size from mobile_scanner
                final captureSize = capture.size;
                
                // Track if any QR code is in the frame area
                bool anyBarcodeInFrame = false;
                
                // Check each barcode
                for (final barcode in capture.barcodes) {
                  if (barcode.rawValue == null) continue;
                  
                  // Check if barcode is inside the frame
                  bool isInFrame = _isBarcodeInFrame(
                    barcode.corners,
                    captureSize,
                    Rect.fromLTRB(frameLeft, frameTop, frameRight, frameBottom),
                    screenSize
                  );
                  
                  if (isInFrame) {
                    anyBarcodeInFrame = true;
                    
                    // Validate format
                    if (_isValidFormat(decryptCaesarHex(barcode.rawValue!, cipherKey))) {
                      // Valid QR code found, hide any warnings
                      if (showInvalidQRWarning) {
                        setState(() {
                          showInvalidQRWarning = false;
                        });
                      }
                      
                      // Trigger vibration feedback for successful scan
                      _vibrateOnSuccess();

                      _showScanResultDialog(decryptCaesarHex(barcode.rawValue!, cipherKey));
                      break;
                    } else {
                      // Show warning for invalid QR code
                      if (!showInvalidQRWarning) {
                        setState(() {
                          showInvalidQRWarning = true;
                        });
                        
                        // Trigger vibration feedback for error
                        _vibrateOnError();
                        
                        // Start or reset the warning timer
                        _warningTimer?.cancel();
                        _warningTimer = Timer(const Duration(seconds: 3), () {
                          if (mounted) {
                            setState(() {
                              showInvalidQRWarning = false;
                            });
                          }
                        });
                      } else {
                        // Reset the timer if warning is already showing
                        _warningTimer?.cancel();
                        _warningTimer = Timer(const Duration(seconds: 3), () {
                          if (mounted) {
                            setState(() {
                              showInvalidQRWarning = false;
                            });
                          }
                        });
                      }
                    }
                  }
                }
                
                // Clear warning if no barcode detected in frame
                if (!anyBarcodeInFrame && showInvalidQRWarning) {
                  _warningTimer?.cancel(); // Cancel any pending timer
                  setState(() {
                    showInvalidQRWarning = false;
                  });
                }
              }
            },
          ),
          
          // Overlay controls
          SafeArea(
            child: Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).size.width * 0.035, left: MediaQuery.of(context).size.width * 0.07, right: MediaQuery.of(context).size.width * 0.07),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Image.asset(
                          'lib/assets/PopMart.png',
                          width: MediaQuery.of(context).size.width * 0.4,
                      ),
                      // Control buttons
                      Row(
                        children: [
                          // Torch control
                          GestureDetector(
                            onTap: () {
                              controller.toggleTorch();
                              setState(() {
                                isTorchOn = !isTorchOn;
                              });
                            },
                            child: Icon(
                              isTorchOn ? Icons.flash_off : Icons.flash_on,
                              color: AppColors.backgroundLight,
                              size: MediaQuery.of(context).size.width * 0.06,
                            ),
                          ),

                          SizedBox(width: MediaQuery.of(context).size.width * 0.05),

                          // Settings button
                          if (showSettingsButton)
                            GestureDetector(
                              onTap: _showSettingsDialog,
                              child: Icon(
                                Icons.settings, 
                                color: AppColors.backgroundLight,
                                size: MediaQuery.of(context).size.width * 0.06,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          
          // Overlay scanning frame
          Center(
            child: Container(
              width: MediaQuery.of(context).size.width * 0.6,
              height: MediaQuery.of(context).size.width * 0.6,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.backgroundLight, width: 2.0),
                borderRadius: BorderRadius.circular(MediaQuery.of(context).size.width * 0.05),
              ),
            ),
          ),
          
          // Invalid QR Warning dialog
          if (showInvalidQRWarning)
            Positioned(
              bottom: 100,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                  decoration: BoxDecoration(
                    color: Colors.red.shade600,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryLight.withOpacity(0.3),
                        blurRadius: 8,
                        spreadRadius: 1,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.warning_rounded,
                        color: AppColors.backgroundLight,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Invalid QR Code',
                        style: TextStyle(
                          color: AppColors.backgroundLight,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Check if barcode is inside the frame
  bool _isBarcodeInFrame(
    List<Offset> corners,
    Size captureSize,
    Rect frameRect,
    Size screenSize,
  ) {
    if (corners.isEmpty) return false;
    
    // Convert corners to screen space
    List<Offset> screenCorners = [];
    
    // Calculate center of barcode
    double centerX = 0;
    double centerY = 0;
    
    for (var corner in corners) {
      // Normalize the corner coordinates
      final normalizedX = corner.dx / captureSize.width;
      final normalizedY = corner.dy / captureSize.height;
      
      // Convert to screen coordinates
      final screenX = normalizedX * screenSize.width;
      final screenY = normalizedY * screenSize.height;
      
      centerX += screenX;
      centerY += screenY;
      
      screenCorners.add(Offset(screenX, screenY));
    }
    
    // Calculate barcode center
    centerX /= corners.length;
    centerY /= corners.length;
    
    // Calculate barcode dimensions
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    
    for (var corner in screenCorners) {
      minX = math.min(minX, corner.dx);
      minY = math.min(minY, corner.dy);
      maxX = math.max(maxX, corner.dx);
      maxY = math.max(maxY, corner.dy);
    }
    
    double width = maxX - minX;
    double height = maxY - minY;
    
    // Get frame inset to make detection stricter
    double insetFactor = 0.1; // 10% inset from each edge
    Rect stricterFrame = Rect.fromLTRB(
      frameRect.left + frameRect.width * insetFactor,
      frameRect.top + frameRect.height * insetFactor,
      frameRect.right - frameRect.width * insetFactor,
      frameRect.bottom - frameRect.height * insetFactor
    );
    
    // Perform multiple checks
    bool centerInFrame = stricterFrame.contains(Offset(centerX, centerY));
    bool cornersInFrame = screenCorners.every((corner) => stricterFrame.contains(corner));
    
    // Calculate what percentage of the barcode is inside the frame
    double overlapLeft = math.max(stricterFrame.left, minX);
    double overlapTop = math.max(stricterFrame.top, minY);
    double overlapRight = math.min(stricterFrame.right, maxX);
    double overlapBottom = math.min(stricterFrame.bottom, maxY);
    
    bool hasOverlap = overlapLeft < overlapRight && overlapTop < overlapBottom;
    double overlapArea = hasOverlap ? (overlapRight - overlapLeft) * (overlapBottom - overlapTop) : 0;
    double barcodeArea = width * height;
    double overlapPercentage = barcodeArea > 0 ? overlapArea / barcodeArea : 0;
    
    // Strict criteria: center must be in frame AND either all corners in frame OR 95% overlap
    bool isInFrame = centerInFrame && (cornersInFrame || overlapPercentage > 0.95);
    
    return isInFrame;
  }

  bool _isValidFormat(String code) {
    // Expected format: <Date>/<TimeSlot>/<QueueNumber>
    final parts = code.split('/');
    if (parts.length != 3) {
      return false;
    }
    
    // Basic validation - you can enhance this based on your requirements
    final date = parts[0];
    final timeSlot = parts[1];
    final queueNumber = parts[2];
    
    return date.isNotEmpty && timeSlot.isNotEmpty && queueNumber.isNotEmpty;
  }

  void _showScanResultDialog(String code) {
    // Parse the code
    final parts = code.split('/');
    final date = parts[0];
    final timeSlotRaw = parts[1];
    final queueNumber = parts[2];
    
    setState(() {
      isDialogShowing = true;
      isScannerActive = false; // Disable scanning but keep widget mounted
    });
    
    // Check if date matches today
    final now = DateTime.now();
    final todayFormatted = "${now.day} ${_getMonthName(now.month)} ${now.year}";
    final isDateMatch = date == todayFormatted || manualCheckingMode;
    
    // Check if time slot matches current time (including minutes)
    DateTime timeSlotStart = DateTime.now();
    DateTime timeSlotEnd = DateTime.now();
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async {
          // Prevent dismissal with back button
          setState(() {
            isDialogShowing = false;
            isScannerActive = true;
            isSending = false;
            isSuccess = false;
            isFailed = false;
          });
          return false;
        },
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
          clipBehavior: Clip.antiAlias,
          backgroundColor: AppColors.backgroundLight,
          child: ConstrainedBox(
            key: _boxKey,
            constraints: BoxConstraints(maxWidth: 500),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final boxWidth = constraints.maxWidth;
                
                return FutureBuilder<List<dynamic>>(
                  future: isCellChecked(int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), _columnLetterToNumber(columnStart) + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing), date),
                  builder: (context, snapshot) {

                    debugPrint('Queue Number: ${snapshot.data}');
                    
                    // Show loading indicator while waiting
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Container(
                        padding: EdgeInsets.symmetric(vertical: boxWidth * 0.1),
                        constraints: BoxConstraints(maxWidth: 500, maxHeight: boxWidth * 0.5),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(
                                color: Colors.blue,
                              ),
                              SizedBox(height: 16),
                              Text(
                                'Verifying ticket...',
                                style: TextStyle(
                                  fontSize: boxWidth * 0.06,
                                  fontWeight: FontWeight.w500,
                                  color: AppColors.primaryLight,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }
                    
                    // When data is loaded, show content
                    final bool isEntered = snapshot.data?[0] ?? false;
                    final bool isExited = snapshot.data?[1] ?? false;
                    final String timeSlot = snapshot.data?[2] ?? '';
                    final bool isFailed2 = !isEntered && !isExited && timeSlot == "error";

                    if (timeSlot.toLowerCase() != "extra") {
                      final startTimeString = timeSlot.replaceAll(" ", "").split('-').first;
                      final endTimeString = timeSlot.replaceAll(" ", "").split('-').last;

                      // Parse time in format like "10:00" or "10:00 AM"
                      final startTimeParts = startTimeString.split(':');
                      final endTimeParts = endTimeString.split(':');
                      
                      int startHour = 0;
                      int startMinute = 0;
                      int endHour = 0;
                      int endMinute = 0;
                      
                      if (startTimeParts.length >= 2) {
                        startHour = int.tryParse(startTimeParts[0]) ?? 0;
                        // Handle cases like "10:00 AM" by extracting just the number part
                        String minuteStr = startTimeParts[1].replaceAll(RegExp(r'[^0-9]'), '');
                        startMinute = int.tryParse(minuteStr) ?? 0;
                        
                        // Check for AM/PM
                        if (startTimeString.toLowerCase().contains('pm') && startHour < 12) {
                          startHour += 12;
                        }
                        if (startTimeString.toLowerCase().contains('am') && startHour == 12) {
                          startHour = 0;
                        }
                      }
                      
                      if (endTimeParts.length >= 2) {
                        endHour = int.tryParse(endTimeParts[0]) ?? 0;
                        // Handle cases like "11:00 AM" by extracting just the number part
                        String minuteStr = endTimeParts[1].replaceAll(RegExp(r'[^0-9]'), '');
                        endMinute = int.tryParse(minuteStr) ?? 0;
                        
                        // Check for AM/PM
                        if (endTimeString.toLowerCase().contains('pm') && endHour < 12) {
                          endHour += 12;
                        }
                        if (endTimeString.toLowerCase().contains('am') && endHour == 12) {
                          endHour = 0;
                        }
                      }

                      timeSlotStart = DateTime(now.year, now.month, now.day, startHour, startMinute);
                      timeSlotEnd = DateTime(now.year, now.month, now.day, endHour, endMinute);
                    }

                    final isTimeMatch = (now.isAfter(timeSlotStart) || now.isAtSameMomentAs(timeSlotStart)) && now.isBefore(timeSlotEnd) || manualCheckingMode || timeSlot.toLowerCase() == "extra";

                    final isDelayed = timeSlotRaw != timeSlot;

                    final bool hasWarnings = (!isDateMatch || !isTimeMatch || isExited) && !(isEntered && !isExited);
                    
                    // Determine the status icon and colors
                    List<Color> gradientColors;
                    
                    if (hasWarnings) {
                      // Warning icon
                      gradientColors = [Colors.orange.shade300, Colors.orange.shade500];
                    } else if (isEntered) {
                      // Exit icon
                      gradientColors = [Colors.red.shade300, Colors.red.shade500];
                    } else {
                      // Entry icon
                      gradientColors = [Colors.green.shade300, Colors.green.shade500];
                    }
                    
                    return StatefulBuilder(
                      builder: (context, setDialogState) {
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Colored top section with icon
                            Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.bottomCenter,
                              children: [
                                // Gradient background
                                Container(
                                  width: double.infinity,
                                  height: boxWidth * 0.275 * 1.25,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: isSending ? [Colors.grey.shade300, Colors.grey.shade500] : isSuccess ? [Colors.green.shade300, Colors.green.shade500] : (isFailed || isFailed2) ? [Colors.red.shade300, Colors.red.shade500] : gradientColors,
                                    ),
                                  ),
                                ),
                                // Centered status icon
                                Positioned(
                                  bottom: -(boxWidth * 0.275) / 2,
                                  child: Container(
                                    width: boxWidth * 0.275,
                                    height: boxWidth * 0.275,
                                    padding: EdgeInsets.all(boxWidth*0.05),
                                    decoration: BoxDecoration(
                                      color: AppColors.backgroundLight,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColors.primaryLight.withOpacity(0.1),
                                          blurRadius: 12,
                                          spreadRadius: 1,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: FittedBox(
                                      fit: BoxFit.contain,
                                      alignment: Alignment.center,
                                      child: ShaderMask(
                                        shaderCallback: (Rect bounds) {
                                          return LinearGradient(
                                            colors: isSending ? [Colors.grey.shade300, Colors.grey.shade500] : isSuccess ? [Colors.green.shade300, Colors.green.shade500] : (isFailed || isFailed2) ? [Colors.red.shade300, Colors.red.shade500] : gradientColors,
                                            begin: Alignment.topLeft,
                                            end: Alignment.bottomRight,
                                          ).createShader(bounds);
                                        },
                                        child: isSending 
                                          ? Container(
                                            padding: EdgeInsets.all(boxWidth * 0.025),
                                            child: CircularProgressIndicator(
                                              color: AppColors.primaryLight,
                                            ),
                                            )
                                          : isSuccess 
                                          ? Icon(
                                            Icons.check_rounded,
                                            color: AppColors.backgroundLight,
                                          )
                                          : (isFailed || isFailed2) 
                                          ? Icon(
                                            Icons.error_rounded,
                                            color: AppColors.backgroundLight,
                                          )
                                          : Icon(
                                            hasWarnings ? Icons.warning_rounded : 
                                            isEntered ? Icons.exit_to_app : Icons.login_rounded,
                                            color: AppColors.backgroundLight,
                                          )
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            
                            // Content section - add padding at top for the overlapping icon
                            Container(
                              padding: EdgeInsets.fromLTRB(boxWidth * 0.1, (boxWidth * 0.275)/2 + 15, boxWidth * 0.1, boxWidth * 0.1),
                              width: double.infinity,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Header
                                  Center(
                                    child: Text(
                                      isSending ? 'Sending Data...' : isSuccess ? 'Success' : (isFailed || isFailed2) ? 'Failed' : 'Visitor Details',
                                      style: TextStyle(
                                        fontSize: boxWidth * 0.1,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.primaryLight,
                                      ),
                                    ),
                                  ),

                                  if (isFailed2 || isFailed)
                                    Center(
                                      child: Text(
                                        isFailed2 ? "Failed Accessing Sheets" : "Failed Sending Data",
                                        style: TextStyle(
                                          fontSize: boxWidth * 0.05,
                                          fontWeight: FontWeight.w400,
                                          color: AppColors.primaryLight,
                                        ),
                                      ),
                                    ),
                                  
                                  const SizedBox(height: 20),
                                  
                                  // Scrollable content area
                                  if (!isSending && !isSuccess && !(isFailed || isFailed2))
                                    Container(
                                      constraints: BoxConstraints(
                                        maxHeight: MediaQuery.of(context).size.height * 0.5, // Limit height to 50% of screen
                                      ),
                                      child: SingleChildScrollView(
                                        physics: ClampingScrollPhysics(),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // Date & Time
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Expanded(
                                                  flex: 1,
                                                  child: _infoColumn('Date', date, false, boxWidth, !isDateMatch, false),
                                                ),
                                                SizedBox(width: boxWidth * 0.045),
                                                Expanded(
                                                  flex: 1,
                                                  child: _infoColumn('Time Slot', timeSlot, false, boxWidth, !isTimeMatch, isDelayed),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 20),
                                
                                            // Queue Number - Ensure left alignment
                                            Align(
                                              alignment: Alignment.centerLeft,
                                              child: _infoColumn('Queue Number', queueNumber, true, boxWidth, false, false),
                                            ),
                                            const SizedBox(height: 20),
                                            
                                            // Warning Section
                                            if (hasWarnings || (isEntered && !isExited && !isTimeMatch))
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                                                decoration: BoxDecoration(
                                                  color: Colors.red.withOpacity(0.1),
                                                  borderRadius: BorderRadius.circular(10),
                                                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                                                ),
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Icon(
                                                          Icons.warning_amber_rounded, 
                                                          color: Colors.red,
                                                          size: boxWidth * 0.065,
                                                        ),
                                                        const SizedBox(width: 6),
                                                        Text(
                                                          'Warning',
                                                          style: TextStyle(
                                                            color: Colors.red,
                                                            fontWeight: FontWeight.w600,
                                                            fontSize: boxWidth * 0.06,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                    const SizedBox(height: 8),
                                                    if (!isDateMatch)
                                                      _buildWarningItem('The date does not match today\'s date (Today: $todayFormatted)', boxWidth),
                                                    if (!isTimeMatch && !isEntered)
                                                      _buildWarningItem('This ticket is scheduled for $timeSlot', boxWidth),
                                                    if (!isTimeMatch && isEntered)
                                                      _buildWarningItem('This visitor has exceeded the time limit', boxWidth),
                                                    if (isExited)
                                                      _buildWarningItem('This ticket has already been used', boxWidth),
                                                  ],
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  
                      
                                  // Buttons
                                  if (!isSending) ...[

                                    if (!isSuccess && !(isFailed || isFailed2))
                                      const SizedBox(height: 20),
                                    
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        // Close button
                                        Expanded(
                                          child: OutlinedButton(
                                            onPressed: () {
                                              Navigator.of(context).pop();
                                              Future.delayed(Duration(milliseconds: 100), () {
                                                setState(() {
                                                  isDialogShowing = false;
                                                  isScannerActive = true; // Reactivate scanner when closing dialog
                                                  isSending = false;
                                                  isSuccess = false;
                                                  isFailed = false;
                                                });
                                              });
                                            },
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: Colors.blue,
                                              side: const BorderSide(color: Colors.blue),
                                              padding: const EdgeInsets.symmetric(vertical: 16),
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(32),
                                              ),
                                            ),
                                            child: Text(
                                              'Close',
                                              style: TextStyle(
                                                fontSize: boxWidth * 0.055,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                        
                                        // Add action button only if there are no warnings
                                        if (!hasWarnings && !(isFailed || isFailed2) && !isSuccess) ...[
                                          const SizedBox(width: 12),
                                          
                                          // Accept button
                                          Expanded(
                                            child: TextButton(
                                              onPressed: isEntered
                                                ? () async {
                                                  setDialogState(() {
                                                    isSending = true;
                                                  });
                                                  // Handle exit action
                                                  final success = await sendDataToSheet(
                                                    row: int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), 
                                                    col: _columnLetterToNumber(columnStart) + 1 + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing),
                                                    value: '✅', 
                                                    sheetName: date
                                                  );
                                                  if (success) {
                                                    setState(() {
                                                      isSuccess = true;
                                                      isFailed = false;
                                                    });
                                                  } else {
                                                    setState(() {
                                                      isFailed = true;
                                                      isSuccess = false;
                                                    });
                                                  }
                                                  setDialogState(() {
                                                    isSending = false;
                                                  });
                                                } 
                                                : () async {
                                                  setDialogState(() {
                                                    isSending = true;
                                                  });
                                                  // Handle entry action
                                                  final success = await sendDataToSheet(
                                                    row: int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), 
                                                    col: _columnLetterToNumber(columnStart) + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing), 
                                                    value: '✅', 
                                                    sheetName: date
                                                  );
                                                  if (success) {
                                                    setState(() {
                                                      isSuccess = true;
                                                      isFailed = false;
                                                    });
                                                  } else {
                                                    setState(() {
                                                      isFailed = true;
                                                      isSuccess = false;
                                                    });
                                                  }
                                                  setDialogState(() {
                                                    isSending = false;
                                                  });
                                                },
                                              style: TextButton.styleFrom(
                                                backgroundColor: isEntered ? Colors.red : Colors.green,
                                                foregroundColor: AppColors.backgroundLight,
                                                padding: const EdgeInsets.symmetric(vertical: 16),
                                                shape: RoundedRectangleBorder(
                                                  borderRadius: BorderRadius.circular(32),
                                                ),
                                              ),
                                              child: Text(
                                                isEntered ? 'Exit' : 'Enter',
                                                style: TextStyle(
                                                  fontSize: boxWidth * 0.055,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    )
                                  ],
                                ],
                              ),
                            ),
                          ],
                        );
                      }
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildWarningItem(String text, double boxWidth) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '•',
            style: TextStyle(
              color: Colors.red, 
              fontSize: boxWidth * 0.05
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.start,
              style: TextStyle(
                color: Colors.red,
                fontSize: boxWidth * 0.05,
              ),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _infoColumn(String label, String value, bool isQueueNumber, double boxWidth, bool hasWarnings, bool isDelayed) {
    return SizedBox(
      width: isQueueNumber ? boxWidth * 0.8 : boxWidth * 0.45,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isDelayed)
                Icon(
                  Icons.update,
                  color: Colors.blue,
                  size: boxWidth * 0.05,
                ),

              if (isDelayed)
                const SizedBox(width: 2),

              Text(
                label,
                style: TextStyle(
                  fontSize: boxWidth * 0.05,
                  color: AppColors.primaryLight.withOpacity(0.75),
                ),
              ),

              if (hasWarnings)
                const SizedBox(width: 6),

              if (hasWarnings)
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orange,
                  size: boxWidth * 0.05,
                ),
            ],
          ),
  
          if (!isQueueNumber)
            const SizedBox(height: 4),
          
          if (isQueueNumber)
            Padding(
              padding: EdgeInsets.only(right: boxWidth * 0.1),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    height: 0.995,
                    fontSize: boxWidth * 0.22,
                    color: AppColors.primaryLight,
                  ),
                ),
              ),
            )
          else
            SizedBox(
              width: boxWidth * 0.45,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: boxWidth * 0.062,  
                    color: AppColors.primaryLight,
                  ),
                ),
              ),
            )
        ],
      ),
    );
  }
  
  String _getMonthName(int month) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return months[month - 1];
  }

  // Add vibration feedback methods
  Future<void> _vibrateOnSuccess() async {
    // Check if device supports vibration
    if (await Vibration.hasVibrator()) {
      Vibration.vibrate(duration: 200);
    }
  }
  
  Future<void> _vibrateOnError() async {
    // Check if device supports vibration
    if (await Vibration.hasVibrator()) {
      // Pattern for error: short, pause, short
      Vibration.vibrate(pattern: [100, 100, 100]);
    }
    
  }
} 