# test_framework.gd
#
# Minimales, eigenes Test-Framework (kein Addon installiert). Sammelt
# Pass/Fail-Ergebnisse über `check()`/`check_eq()` und druckt am Ende eine
# Zusammenfassung. Wird vom TestRunner pro Testfall genutzt.
class_name TestFramework
extends RefCounted

var pass_count := 0
var fail_count := 0
var failures: Array[String] = []
var current_test := ""


## Markiert den Beginn eines neuen benannten Testfalls - alle folgenden
## check()-Aufrufe werden bis zum nächsten begin() diesem Namen zugeordnet.
func begin(test_name: String) -> void:
	current_test = test_name
	print("--- ", test_name, " ---")


## Grundlegende Prüfung. message beschreibt, WAS geprüft wird (nicht nur
## das Ergebnis), damit ein Fail-Log auch ohne Quellcode verständlich ist.
func check(condition: bool, message: String = "") -> bool:
	if condition:
		pass_count += 1
		print("  [PASS] ", message)
	else:
		fail_count += 1
		var full_message := current_test + ": " + message
		failures.append(full_message)
		print("  [FAIL] ", message)
	return condition


## Vergleichs-Prüfung mit automatischer "erwartet X, war Y"-Meldung.
func check_eq(actual, expected, message: String = "") -> bool:
	var ok: bool = actual == expected
	var full_message := message + " (erwartet " + str(expected) + ", war " + str(actual) + ")"
	return check(ok, full_message)


func print_summary() -> void:
	print("")
	print("============================================================")
	print("ERGEBNIS: ", pass_count, " bestanden, ", fail_count, " fehlgeschlagen")
	if fail_count > 0:
		print("Fehlgeschlagene Checks:")
		for f in failures:
			print("  - ", f)
	print("============================================================")


func all_passed() -> bool:
	return fail_count == 0
