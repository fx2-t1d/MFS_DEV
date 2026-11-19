import SwiftUI
import UIKit

/// Typed-in food: a one-row table with an optional photo. Entered grams are for the whole meal.
struct ManualFoodView: View {
    @EnvironmentObject private var foodStore: AcceptedFoodStore
    @State private var name = ""
    @State private var carbs = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var fiber = ""
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

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if problem(carbs, optional: false) || problem(protein, optional: false) { return "Carbs and protein are required, in grams." }
        if problem(fat, optional: true) || problem(fiber, optional: true) { return "Fat and fiber must be numbers in grams, or empty." }
        if let fiberGrams = grams(fiber), let carbGrams = grams(carbs), fiberGrams > carbGrams { return "Fiber cannot exceed carbs." }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        header("Name"); header("Carbs (g)"); header("Protein (g)"); header("Fat (g)\noptional"); header("Fiber (g)\noptional")
                    }
                    GridRow {
                        TextField("Food", text: $name).textFieldStyle(.roundedBorder)
                        field($carbs); field($protein); field($fat); field($fiber)
                    }
                }
            } header: {
                Text("Whole meal")
            } footer: {
                Text("Grams for everything you will eat, not per 100 g. Carbs include fiber.")
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
                if let message = validationMessage, !(name.isEmpty && carbs.isEmpty && protein.isEmpty) {
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
        guard validationMessage == nil, let carbGrams = grams(carbs), let proteinGrams = grams(protein) else { return }
        var nutrients: [NutritionField: Double] = [.carbohydrates: carbGrams, .protein: proteinGrams]
        if let fatGrams = grams(fat) { nutrients[.totalFat] = fatGrams }
        if let fiberGrams = grams(fiber) { nutrients[.fiber] = fiberGrams }
        // Modeled as one 100 g serving so the entered grams are the meal totals.
        let product = OpenFoodFactsProduct(
            barcode: "", name: name.trimmingCharacters(in: .whitespaces), brands: nil,
            servingSize: "whole meal", nutritionValues: [:], nutrientsPer100g: nutrients,
            servingQuantity: 100, servingUnit: "g")
        foodStore.accept(AcceptedFood(product: product, servings: 1, photoJPEG: photo?.jpegData(compressionQuality: 0.7)))
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
