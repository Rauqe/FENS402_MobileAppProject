import '../models/patient.dart';

/// Holds the currently logged-in user across the app.
/// Set on login, cleared on logout.
class AppSession {
  AppSession._();
  static final AppSession instance = AppSession._();

  Patient? currentPatient;
  bool isCaregiver = false;

  void loginAsCaregiver() {
    isCaregiver = true;
    currentPatient = null;
  }

  void loginAsPatient(Patient patient) {
    isCaregiver = false;
    currentPatient = patient;
  }

  void logout() {
    isCaregiver = false;
    currentPatient = null;
  }

  String? get currentPatientId => currentPatient?.patientId;
}
