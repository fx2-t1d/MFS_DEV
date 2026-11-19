import SwiftUI
import UIKit

/// Typed-in food: a table of rows with an optional photo. Each row is a whole-meal amount or per serving.
struct ManualFoodView: View {
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    private struct Row: Identifiable {
        let id = UUID()
        var name = ""
        var carbs = ""
        var protein = ""
        var fat = ""
        var fiber = ""
        var perServing = false
        var servings = ""

        var isBlank: Bool { name.isEmpty && carbs.isEmpty && protein.isEmpty && fat.isEmpty && fiber.isEmpty && servings.isEmpty }
    }

    @State private var rows = [Row()]
    @State private var photo: UIImage?
    @State private var showCamera = false

    private func grams(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func problem(_ text: String, optional: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? !optional : grams(text) == nil
    }

    private func message(for row: Row) -> String? {
        if row.name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if problem(row.carbs, optional: false) || problem(row.protein, optional: false) { return "Carbs and protein are required, in grams." }
        if problem(row.fat, optional: true) || problem(row.fiber, optional: true) { return "Fat and fiber must be numbers in grams, or empty." }
        if let fiberGrams = grams(row.fiber), let carbGrams = grams(row.carbs), fiberGrams > carbGrams { return "Fiber cannot exceed carbs." }
        if row.perServing, (grams(row.servings) ?? 0) <= 0 { return "Enter the number of servings." }
        return nil
    }

    private var validationMessage: String? {
        for (index, row) in rows.enumerated() {
            if let text = message(for: row) { return rows.count > 1 ? "Row \(index + 1): \(text)" : text }
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                ForEach($rows) { $row in
                    VStack(alignment: .leading, spacing: 6) {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            if row.id == rows.first?.id {
                                GridRow {
                                    header("Name"); header(row.perServing ? "Carbs (g)\nper serving" : "Carbs (g)"); header("Protein (g)"); header("Fat (g)\noptional"); header("Fiber (g)\noptional")
                                }
                            }
                            GridRow {
                                TextField("Food", text: $row.name).textFieldStyle(.roundedBorder)
                                field($row.carbs); field($row.protein); field($row.fat); field($row.fiber)
                            }
                        }
                        HStack {
                            Toggle("Per serving", isOn: $row.perServing).fixedSize()
                            if row.perServing {
                                TextField("Servings", text: $row.servings)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 100)
                                Text("servings").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        if rows.count > 1 {
                            Button("Delete", role: .destructive) { rows.removeAll { $0.id == row.id } }
                        }
                    }
                }
                Button("Add row", systemImage: "plus") { rows.append(Row()) }
            } header: {
                Text("Food")
            } footer: {
                Text("Unchecked: grams for everything you will eat. Per serving: grams in one serving, multiplied by the servings you enter. Carbs include fiber.")
            }

            Section("Photo (optional)") {
                if let photo {
                    Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 180)
                    Button("Remove photo", role: .destructive) { self.photo = nil }
                }
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button(photo == nil ? "Take a photo" : "Retake photo", systemImage: "camera") { showCamera = true }
                } else {
                    Text("Camera unavailable on this device.").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                if let message = validationMessage, !rows.allSatisfy(\.isBlank) {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                Button("Accept") { accept() }.disabled(validationMessage != nil)
            }
        }
        .navigationTitle("Text")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in photo = image }.ignoresSafeArea()
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func field(_ text: Binding<String>) -> some View {
        TextField("0", text: text)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 52)
    }

    private func accept() {
        guard validationMessage == nil else { return }
        var items: [AcceptedFood] = []
        for row in rows {
            guard let carbGrams = grams(row.carbs), let proteinGrams = grams(row.protein) else { return }
            var nutrients: [NutritionField: Double] = [.carbohydrates: carbGrams, .protein: proteinGrams]
            if let fatGrams = grams(row.fat) { nutrients[.totalFat] = fatGrams }
            if let fiberGrams = grams(row.fiber) { nutrients[.fiber] = fiberGrams }
            // Modeled as 100 g servings so the entered grams are per serving (or the row total).
            let product = OpenFoodFactsProduct(
                barcode: "", name: row.name.trimmingCharacters(in: .whitespaces), brands: nil,
                servingSize: row.perServing ? "serving" : "whole meal", nutritionValues: [:], nutrientsPer100g: nutrients,
                servingQuantity: 100, servingUnit: "g")
            items.append(AcceptedFood(product: product, servings: row.perServing ? (grams(row.servings) ?? 1) : 1))
        }
        // The whole table and the photo become one record.
        foodStore.accept(AcceptedMeal(items: items, photoJPEG: photo?.jpegData(compressionQuality: 0.7)))
        rows = [Row()]
        photo = nil
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
