import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'package:vibration/vibration.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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

  Future<void> sendDataToSheet({
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

      if (response.statusCode == 200) {
        print('Sheet update success: ${response.body}');
      } else {
        print('Sheet update failed: ${response.statusCode}');
      }
    } catch (e) {
      print('Error hitting sheet endpoint: $e');
    }
  }

  Future<bool> isCellChecked(int row, int col, String sheetName) async {
    print('Checking cell: $row, $col, $sheetName');

    final url = Uri.parse(
      'https://script.google.com/macros/s/AKfycbwfZ-AbmRPruwQY6KBK-zttEWMrUauup-sKFXykpwnYn46vOjP3GwIDJwmAyVwSi-v5bw/exec?row=$row&col=$col&sheetName=$sheetName',
    );

    final response = await http.get(url);

    if (response.statusCode == 200) {
      final body = response.body.trim();
      return body == 'Checked';
    } else {
      throw Exception('Failed to read cell: ${response.body}');
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
          return false;
        },
        child: StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Text(
                    showMaxAttemptsWarning ? 'Warning' : 'Enter PIN',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
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
                        color: showError ? Colors.red : Colors.grey.shade300,
                        width: 1.5,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      enteredPin.isEmpty ? 'Enter PIN' : 
                      enteredPin.replaceAll(RegExp(r'.'), '•'),
                      style: TextStyle(
                        fontSize: 20,
                        color: enteredPin.isEmpty ? Colors.grey : Colors.white,
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
                          fontSize: 14,
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
                              Icon(Icons.warning_amber_rounded, color: Colors.red, size: 24),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Maximum attempts reached',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.red,
                                    fontSize: 16,
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
                      mainAxisSpacing: 15,
                      crossAxisSpacing: 15,
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
                            color: Colors.transparent,
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
                          color: Colors.transparent,
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
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(
                            showMaxAttemptsWarning ? 'Close' : 'Cancel',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      
                      if (!showMaxAttemptsWarning) ...[
                        const SizedBox(width: 12),
                        
                        // Verify button
                        Expanded(
                          child: ElevatedButton(
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
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                            child: const Text(
                              'Verify',
                              style: TextStyle(
                                fontSize: 18,
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
            ),
          ),
        ),
      ),
    );
  }
  
  // Helper method to build PIN keyboard buttons
  Widget _buildPinButton(String text, VoidCallback onPressed, {required Color color}) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        backgroundColor: color.withOpacity(0.1),
        foregroundColor: Colors.white,
        shape: CircleBorder(),
        side: BorderSide(color: Colors.white),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
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
          return false;
        },
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  const Text(
                    'Scanner Settings',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  
                  const SizedBox(height: 20),

                  // Column and Row settings in a row
                  Row(
                    children: [
                      // Column setting
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Column Start',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: columnController,
                              decoration: InputDecoration(
                                hintText: 'Enter a letter (e.g. F)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              maxLength: 1,
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
                            const Text(
                              'Row Start',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: rowController,
                              decoration: InputDecoration(
                                hintText: 'Enter a number (e.g. 2)',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
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
                  const Text(
                    'Cipher Key',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: cipherController,
                    decoration: InputDecoration(
                      hintText: 'Enter a letter (e.g. G)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    maxLength: 1,
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

                  const Text(
                    'Column Spacing',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: timeSlotColumnSpacingController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: 'Enter a number (e.g. 10)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    maxLength: 2,
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

                  const Text(
                    'Time Slot Ticket Count',
                    style: TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: timeSlotTicketCountController,  
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: 'Enter a number (e.g. 10)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    maxLength: 4,
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
                          fontSize: 16,
                          color: Colors.grey.shade300,
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
                          );
                        },
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 20),
                  
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
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'Cancel',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                      
                      const SizedBox(width: 12),
                      
                      // Save button
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            // Validate and save settings
                            final newColumn = columnController.text.toUpperCase();
                            final newRow = int.tryParse(rowController.text) ?? rowStart;
                            final newCipherKey = cipherController.text.toUpperCase();
                            final newTimeSlotColumnSpacing = int.tryParse(timeSlotColumnSpacingController.text) ?? timeSlotColumnSpacing;
                            final newTimeSlotTicketCount = int.tryParse(timeSlotTicketCountController.text) ?? timeSlotTicketCount;
                            final newManualCheckingMode = manualCheckingMode;
                            
                            if (newColumn.isNotEmpty && 
                                RegExp(r'^[A-Z]$').hasMatch(newColumn) &&
                                newRow > 0 &&
                                newCipherKey.isNotEmpty &&
                                RegExp(r'^[A-Z]$').hasMatch(newCipherKey) &&
                                timeSlotColumnSpacing > 0 &&
                                newTimeSlotTicketCount > 0) {
                              setState(() {
                                columnStart = newColumn;
                                rowStart = newRow;
                                cipherKey = newCipherKey;
                                timeSlotColumnSpacing = newTimeSlotColumnSpacing;
                                timeSlotTicketCount = newTimeSlotTicketCount;
                                manualCheckingMode = newManualCheckingMode;
                              });
                              _saveSettings();
                            }
                            
                            Navigator.of(context).pop();
                            setState(() {
                              isDialogShowing = false;
                              isScannerActive = true; // Reactivate scanner when closing dialog
                            });
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: const Text(
                            'Save',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
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
                final frameSize = 250.0;
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
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 16.0),
                        child: Image.asset(
                          'lib/assets/PopMart.png',
                          width: 180,
                        ),
                      ),
                      // Control buttons
                      Row(
                        children: [
                          // Torch control
                          IconButton(
                            icon: Icon(
                              isTorchOn ? Icons.flash_off : Icons.flash_on,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              controller.toggleTorch();
                              setState(() {
                                isTorchOn = !isTorchOn;
                              });
                            },
                          ),
                          // Settings button
                          if (showSettingsButton)
                            IconButton(
                              icon: const Icon(Icons.settings, color: Colors.white),
                              onPressed: _showSettingsDialog,
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
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2.0),
                borderRadius: BorderRadius.circular(12),
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
                        color: Colors.black.withOpacity(0.3),
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
                        color: Colors.white,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Invalid QR Code',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          
          // Scanning instruction
          Positioned(
            bottom: 50,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(64),
                ),
                child: const Text(
                  'Scan QR Code',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
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
    // Convert barcode corners from capture space to screen space
    List<Offset> screenCorners = [];
    for (var corner in corners) {
      // Normalize the corner coordinates
      final normalizedX = corner.dx / captureSize.width;
      final normalizedY = corner.dy / captureSize.height;
      
      // Convert to screen coordinates
      final screenX = normalizedX * screenSize.width;
      final screenY = normalizedY * screenSize.height;
      
      screenCorners.add(Offset(screenX, screenY));
    }
    
    // Check if ALL corners of the barcode are inside the frame
    // Only consider the barcode valid if it's completely inside the frame
    for (var corner in screenCorners) {
      if (!frameRect.contains(corner)) {
        return false;
      }
    }
    
    return true;
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
    final timeSlot = parts[1];
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
    try {
      final startTimeString = timeSlot.split(' - ').first;
      final endTimeString = timeSlot.split(' - ').last;
      
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
      
      // Set the date part to today to compare only time
      timeSlotStart = DateTime(now.year, now.month, now.day, startHour, startMinute);
      timeSlotEnd = DateTime(now.year, now.month, now.day, endHour, endMinute);
      
      print('Parsed time slot: $timeSlotStart - $timeSlotEnd');
    } catch (e) {
      print('Error parsing time slot: $e');
    }
    final isTimeMatch = (now.isAfter(timeSlotStart) || now.isAtSameMomentAs(timeSlotStart)) && 
                     now.isBefore(timeSlotEnd) || manualCheckingMode;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async {
          // Prevent dismissal with back button
          return false;
        },
        child: Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: FutureBuilder<List<bool>>(
            future: Future.wait([
              isCellChecked(int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), _columnLetterToNumber(columnStart) + 1 + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing), date), // Check exit status
              isCellChecked(int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), _columnLetterToNumber(columnStart) + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing), date), // Check entry status
            ]),
            builder: (context, snapshot) {
              // Show loading indicator while waiting
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 150,
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(
                          color: Colors.blue,
                        ),
                        SizedBox(height: 16),
                        Text(
                          'Verifying ticket...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              
              // When data is loaded, show content
              final bool isExited = snapshot.data?[0] ?? false;
              final bool isEntered = snapshot.data?[1] ?? false;
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
                        height: 100,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: gradientColors,
                          ),
                        ),
                      ),
                      // Centered status icon - positioned to overlap gradient and content
                      Positioned(
                        bottom: -50,
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            color: Color(0xff2A292f),
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26.withOpacity(0.2),
                                blurRadius: 8,
                                spreadRadius: 1,
                                offset: Offset(0, 3),
                              ),
                              BoxShadow(
                                color: Colors.black12.withOpacity(0.2),
                                blurRadius: 4,
                                spreadRadius: 0.5, 
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Center(
                            child: ShaderMask(
                              shaderCallback: (Rect bounds) {
                                return LinearGradient(
                                  colors: gradientColors,
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                ).createShader(bounds);
                              },
                              child: Icon(
                                hasWarnings ? Icons.warning_rounded : 
                                isEntered ? Icons.exit_to_app : Icons.login_rounded,
                                size: hasWarnings ? 60 : 55,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  
                  // Content section - add padding at top for the overlapping icon
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 55, 32, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Center(
                          child: Text(
                            'Visitor Details',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        
                        const SizedBox(height: 20),
    
                        // Date & Time
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            _infoColumn('Date', date, false),
                            const SizedBox(width: 10),
                            _infoColumn('Time Slot', timeSlot, false),
                          ],
                        ),
                        const SizedBox(height: 20),
    
                        // Queue Number - Ensure left alignment
                        Align(
                          alignment: Alignment.centerLeft,
                          child: _infoColumn('Queue Number', queueNumber, true),
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
                                    const Icon(Icons.warning_amber, color: Colors.red),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Warning',
                                      style: TextStyle(
                                        color: Colors.red,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                if (!isDateMatch)
                                  _buildWarningItem('The date does not match today\'s date (Today: $todayFormatted)'),
                                if (!isTimeMatch && !isEntered)
                                  _buildWarningItem('This ticket is scheduled for ${timeSlotStart.hour}:${timeSlotStart.minute.toString().padLeft(2, '0')} - ${timeSlotEnd.hour}:${timeSlotEnd.minute.toString().padLeft(2, '0')}'),
                                if (!isTimeMatch && isEntered)
                                  _buildWarningItem('This visitor has exceeded time limit'),
                                if (isExited)
                                  _buildWarningItem('This ticket has already been used'),
                              ],
                            ),
                          ),
                        
                        const SizedBox(height: 20),
    
                        // Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Close button
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
                                  padding: const EdgeInsets.symmetric(vertical: 12),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: const Text(
                                  'Close',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            
                            // Add action button only if there are no warnings
                            if (!hasWarnings) ...[
                              const SizedBox(width: 12),
                              
                              // Accept button
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: isEntered
                                    ? () {
                                        // Handle exit action
                                        sendDataToSheet(
                                          row: int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), 
                                          col: _columnLetterToNumber(columnStart) + 1 + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing),
                                          value: '✅', 
                                          sheetName: date
                                        );
                                        Navigator.of(context).pop();
                                        setState(() {
                                          isDialogShowing = false;
                                          isScannerActive = true; // Reactivate scanner when closing dialog
                                        });
                                      } 
                                    : () {
                                        // Handle entry action
                                        sendDataToSheet(
                                          row: int.parse(queueNumber) + (rowStart - 1) - (timeSlotTicketCount * ((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount)), 
                                          col: _columnLetterToNumber(columnStart) + (((int.parse(queueNumber) - 1) ~/ timeSlotTicketCount) * timeSlotColumnSpacing), 
                                          value: '✅', 
                                          sheetName: date
                                        );

                                        Navigator.of(context).pop();
                                        setState(() {
                                          isDialogShowing = false;
                                          isScannerActive = true; // Reactivate scanner when closing dialog
                                        });
                                      },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isEntered ? Colors.red : Colors.blue,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  child: Text(
                                    isEntered ? 'Exit' : 'Enter',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        )
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
  
  Widget _buildWarningItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '•',
            style: TextStyle(color: Colors.red, fontSize: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              textAlign: TextAlign.start,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _infoColumn(String label, String value, bool isQueueNumber) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: Colors.grey[500], fontSize: 16),
        ),
        if (!isQueueNumber)
          const SizedBox(height: 4),
        Text(
          value,
          style: !isQueueNumber 
          ? const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 20
          )
          : const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 64,
            height: 0.99,
          ),
        )
      ],
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