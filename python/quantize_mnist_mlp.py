from __future__ import annotations

import json
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


# ============================================================
# Configuration
# ============================================================

CHECKPOINT_PATH = Path("./outputs/mnist_mlp_float.pth")
DATA_DIR = Path("./data")
OUTPUT_DIR = Path("./outputs/quantized")

BATCH_SIZE = 256
NUM_WORKERS = 2

# shift 탐색에는 일부 데이터만 사용하고,
# 최종 정확도는 전체 10,000개로 평가한다.
SEARCH_SAMPLE_COUNT = 2000

SHIFT1_MIN = 0
SHIFT1_MAX = 15

SHIFT2_MIN = 0
SHIFT2_MAX = 15

# RTL 비교용으로 저장할 MNIST 테스트 이미지 index
REFERENCE_SAMPLE_INDEX = 0


# ============================================================
# Model
# ============================================================

class MNISTMLP(nn.Module):
    """
    784 -> 128 -> ReLU -> 10

    현재 RTL에 bias 연산이 없으므로 bias=False
    """

    def __init__(self) -> None:
        super().__init__()

        self.flatten = nn.Flatten()

        self.fc1 = nn.Linear(
            in_features=784,
            out_features=128,
            bias=False,
        )

        self.relu = nn.ReLU()

        self.fc2 = nn.Linear(
            in_features=128,
            out_features=10,
            bias=False,
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.flatten(x)
        x = self.fc1(x)
        x = self.relu(x)
        x = self.fc2(x)

        return x


# ============================================================
# Loading
# ============================================================

def load_model() -> tuple[MNISTMLP, dict]:
    if not CHECKPOINT_PATH.exists():
        raise FileNotFoundError(
            f"Checkpoint not found: {CHECKPOINT_PATH}"
        )

    checkpoint = torch.load(
        CHECKPOINT_PATH,
        map_location="cpu",
    )

    model = MNISTMLP()

    model.load_state_dict(
        checkpoint["model_state_dict"]
    )

    model.eval()

    return model, checkpoint


def load_test_dataset() -> datasets.MNIST:
    return datasets.MNIST(
        root=DATA_DIR,
        train=False,
        transform=transforms.ToTensor(),
        download=True,
    )


# ============================================================
# Quantization
# ============================================================

def quantize_weight_symmetric(
    weight: torch.Tensor,
) -> tuple[torch.Tensor, float]:
    """
    Float weight를 signed int8 -127~127로 양자화한다.

    real_weight ~= int_weight * scale
    """

    max_abs = weight.abs().max().item()

    if max_abs == 0.0:
        scale = 1.0
    else:
        scale = max_abs / 127.0

    quantized = torch.round(weight / scale)
    quantized = torch.clamp(quantized, -127, 127)
    quantized = quantized.to(torch.int8)

    return quantized, scale


def quantize_input(
    images: torch.Tensor,
) -> torch.Tensor:
    """
    ToTensor 결과인 0.0~1.0 입력을 0~127 int8로 변환한다.

    signed 8-bit RTL data_t에서 양수 범위만 사용한다.
    """

    quantized = torch.round(images * 127.0)
    quantized = torch.clamp(quantized, 0, 127)

    return quantized.to(torch.int8)


def requantize_rtl(
    accumulator: torch.Tensor,
    shift_amount: int,
    relu_en: bool,
) -> torch.Tensor:
    """
    RTL requantizer와 동일한 연산 순서:

    1. arithmetic right shift
    2. optional ReLU
    3. signed int8 saturation
    """

    if accumulator.dtype not in (
        torch.int32,
        torch.int64,
    ):
        raise TypeError(
            "Accumulator must be int32 or int64"
        )

    shifted = accumulator >> shift_amount

    if relu_en:
        shifted = torch.clamp_min(shifted, 0)

    saturated = torch.clamp(
        shifted,
        min=-128,
        max=127,
    )

    return saturated.to(torch.int8)


# ============================================================
# Dataset conversion
# ============================================================

def collect_integer_test_data(
    dataset: datasets.MNIST,
) -> tuple[torch.Tensor, torch.Tensor]:
    """
    전체 MNIST 테스트셋을 정수 tensor로 변환한다.

    images_q shape: [10000, 784]
    labels shape:   [10000]
    """

    loader = DataLoader(
        dataset=dataset,
        batch_size=BATCH_SIZE,
        shuffle=False,
        num_workers=NUM_WORKERS,
    )

    image_batches: list[torch.Tensor] = []
    label_batches: list[torch.Tensor] = []

    for images, labels in loader:
        images_q = quantize_input(images)
        images_q = images_q.reshape(images_q.size(0), 784)

        image_batches.append(images_q)
        label_batches.append(labels)

    all_images = torch.cat(image_batches, dim=0)
    all_labels = torch.cat(label_batches, dim=0)

    return all_images, all_labels


# ============================================================
# Accuracy evaluation
# ============================================================

@torch.inference_mode()
def evaluate_float_model(
    model: MNISTMLP,
    dataset: datasets.MNIST,
) -> float:
    loader = DataLoader(
        dataset=dataset,
        batch_size=BATCH_SIZE,
        shuffle=False,
        num_workers=NUM_WORKERS,
    )

    correct = 0
    total = 0

    for images, labels in loader:
        logits = model(images)
        predictions = logits.argmax(dim=1)

        correct += (
            predictions == labels
        ).sum().item()

        total += labels.size(0)

    return correct / total


@torch.inference_mode()
def run_integer_inference(
    images_q: torch.Tensor,
    w1_q: torch.Tensor,
    w2_q: torch.Tensor,
    shift1: int,
    shift2: int,
) -> tuple[
    torch.Tensor,
    torch.Tensor,
    torch.Tensor,
    torch.Tensor,
]:
    """
    RTL과 동일한 2-layer 정수 추론.

    반환:
        acc1      [batch, 128], int32
        hidden_q  [batch, 128], int8
        acc2      [batch, 10],  int32
        output_q  [batch, 10],  int8
    """

    x_i32 = images_q.to(torch.int32)
    w1_i32 = w1_q.to(torch.int32)
    w2_i32 = w2_q.to(torch.int32)

    # PyTorch Linear weight shape: [N, K]
    acc1 = x_i32 @ w1_i32.T

    hidden_q = requantize_rtl(
        accumulator=acc1,
        shift_amount=shift1,
        relu_en=True,
    )

    acc2 = hidden_q.to(torch.int32) @ w2_i32.T

    output_q = requantize_rtl(
        accumulator=acc2,
        shift_amount=shift2,
        relu_en=False,
    )

    return acc1, hidden_q, acc2, output_q


@torch.inference_mode()
def evaluate_integer_accuracy(
    images_q: torch.Tensor,
    labels: torch.Tensor,
    w1_q: torch.Tensor,
    w2_q: torch.Tensor,
    shift1: int,
    shift2: int,
) -> float:
    _, _, _, output_q = run_integer_inference(
        images_q=images_q,
        w1_q=w1_q,
        w2_q=w2_q,
        shift1=shift1,
        shift2=shift2,
    )

    predictions = output_q.to(torch.int32).argmax(dim=1)

    correct = (
        predictions == labels
    ).sum().item()

    return correct / labels.numel()


# ============================================================
# Shift search
# ============================================================

@torch.inference_mode()
def search_best_shifts(
    images_q: torch.Tensor,
    labels: torch.Tensor,
    w1_q: torch.Tensor,
    w2_q: torch.Tensor,
) -> tuple[int, int, float]:
    """
    calibration subset에서 shift1, shift2 조합을 탐색한다.
    """

    sample_count = min(
        SEARCH_SAMPLE_COUNT,
        images_q.size(0),
    )

    search_images = images_q[:sample_count]
    search_labels = labels[:sample_count]

    x_i32 = search_images.to(torch.int32)
    w1_i32 = w1_q.to(torch.int32)
    w2_i32 = w2_q.to(torch.int32)

    # Layer 1 accumulator는 shift1과 무관하므로 한 번만 계산
    acc1 = x_i32 @ w1_i32.T

    best_shift1 = 0
    best_shift2 = 0
    best_accuracy = -1.0

    print()
    print("========================================")
    print("Searching shift amounts")
    print("========================================")
    print(f"Search samples: {sample_count}")

    for shift1 in range(
        SHIFT1_MIN,
        SHIFT1_MAX + 1,
    ):
        hidden_q = requantize_rtl(
            accumulator=acc1,
            shift_amount=shift1,
            relu_en=True,
        )

        layer1_saturation_ratio = (
            (hidden_q == 127)
            .float()
            .mean()
            .item()
        )

        layer1_nonzero_ratio = (
            (hidden_q != 0)
            .float()
            .mean()
            .item()
        )

        acc2 = hidden_q.to(torch.int32) @ w2_i32.T

        best_accuracy_for_shift1 = -1.0
        best_shift2_for_shift1 = 0

        for shift2 in range(
            SHIFT2_MIN,
            SHIFT2_MAX + 1,
        ):
            output_q = requantize_rtl(
                accumulator=acc2,
                shift_amount=shift2,
                relu_en=False,
            )

            predictions = (
                output_q
                .to(torch.int32)
                .argmax(dim=1)
            )

            accuracy = (
                predictions == search_labels
            ).float().mean().item()

            if accuracy > best_accuracy_for_shift1:
                best_accuracy_for_shift1 = accuracy
                best_shift2_for_shift1 = shift2

            if accuracy > best_accuracy:
                best_accuracy = accuracy
                best_shift1 = shift1
                best_shift2 = shift2

        print(
            f"shift1={shift1:2d}  "
            f"best_shift2={best_shift2_for_shift1:2d}  "
            f"accuracy={best_accuracy_for_shift1 * 100:6.2f}%  "
            f"hidden_sat={layer1_saturation_ratio * 100:7.3f}%  "
            f"hidden_nonzero={layer1_nonzero_ratio * 100:7.3f}%"
        )

    print()
    print(
        f"Selected shift1={best_shift1}, "
        f"shift2={best_shift2}, "
        f"search_accuracy={best_accuracy * 100:.2f}%"
    )

    return best_shift1, best_shift2, best_accuracy


# ============================================================
# MEM export
# ============================================================

def int8_to_hex(value: int) -> str:
    """
    signed int8을 8-bit two's complement hex로 변환한다.

    -1   -> ff
    -128 -> 80
    127  -> 7f
    """

    return f"{value & 0xFF:02x}"


def int32_to_hex(value: int) -> str:
    """
    signed int32를 32-bit two's complement hex로 변환한다.
    """

    return f"{value & 0xFFFFFFFF:08x}"


def save_int8_mem(
    tensor: torch.Tensor,
    path: Path,
) -> None:
    values = tensor.detach().cpu().reshape(-1).tolist()

    with path.open("w", encoding="utf-8") as file:
        for value in values:
            file.write(
                int8_to_hex(int(value)) + "\n"
            )


def save_int32_mem(
    tensor: torch.Tensor,
    path: Path,
) -> None:
    values = tensor.detach().cpu().reshape(-1).tolist()

    with path.open("w", encoding="utf-8") as file:
        for value in values:
            file.write(
                int32_to_hex(int(value)) + "\n"
            )


def save_decimal_text(
    tensor: torch.Tensor,
    path: Path,
) -> None:
    values = tensor.detach().cpu().reshape(-1).tolist()

    with path.open("w", encoding="utf-8") as file:
        for index, value in enumerate(values):
            file.write(
                f"{index}: {int(value)}\n"
            )


# ============================================================
# Export
# ============================================================

@torch.inference_mode()
def export_quantized_files(
    dataset: datasets.MNIST,
    w1_q: torch.Tensor,
    w2_q: torch.Tensor,
    w1_scale: float,
    w2_scale: float,
    shift1: int,
    shift2: int,
    float_accuracy: float,
    integer_accuracy: float,
) -> None:
    OUTPUT_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    # --------------------------------------------------------
    # Weight export
    #
    # PyTorch:
    #   fc1 [128, 784]
    #   fc2 [10, 128]
    #
    # RTL BRAM:
    #   layer1 [784, 128]
    #   layer2 [128, 10]
    # --------------------------------------------------------

    w1_rtl = w1_q.T.contiguous()
    w2_rtl = w2_q.T.contiguous()

    save_int8_mem(
        w1_rtl,
        OUTPUT_DIR / "layer1_weight.mem",
    )

    save_int8_mem(
        w2_rtl,
        OUTPUT_DIR / "layer2_weight.mem",
    )

    # --------------------------------------------------------
    # Reference sample
    # --------------------------------------------------------

    image, label = dataset[REFERENCE_SAMPLE_INDEX]

    image_q = quantize_input(
        image.unsqueeze(0)
    ).reshape(1, 784)

    acc1, hidden_q, acc2, output_q = run_integer_inference(
        images_q=image_q,
        w1_q=w1_q,
        w2_q=w2_q,
        shift1=shift1,
        shift2=shift2,
    )

    prediction = (
        output_q
        .to(torch.int32)
        .argmax(dim=1)
        .item()
    )

    save_int8_mem(
        image_q[0],
        OUTPUT_DIR / "reference_input.mem",
    )

    save_int32_mem(
        acc1[0],
        OUTPUT_DIR / "reference_layer1_acc.mem",
    )

    save_int8_mem(
        hidden_q[0],
        OUTPUT_DIR / "reference_layer1_output.mem",
    )

    save_int32_mem(
        acc2[0],
        OUTPUT_DIR / "reference_layer2_acc.mem",
    )

    save_int8_mem(
        output_q[0],
        OUTPUT_DIR / "reference_final_output.mem",
    )

    save_decimal_text(
        hidden_q[0],
        OUTPUT_DIR / "reference_layer1_output.txt",
    )

    save_decimal_text(
        acc2[0],
        OUTPUT_DIR / "reference_layer2_acc.txt",
    )

    save_decimal_text(
        output_q[0],
        OUTPUT_DIR / "reference_final_output.txt",
    )

    configuration = {
        "architecture": {
            "input_size": 784,
            "hidden_size": 128,
            "output_size": 10,
            "bias": False,
        },
        "quantization": {
            "input_range": [0, 127],
            "weight_range": [-127, 127],
            "output_range": [-128, 127],
            "layer1_weight_scale": w1_scale,
            "layer2_weight_scale": w2_scale,
            "layer1_shift_amount": shift1,
            "layer1_relu_en": True,
            "layer2_shift_amount": shift2,
            "layer2_relu_en": False,
        },
        "accuracy": {
            "float_accuracy": float_accuracy,
            "integer_accuracy": integer_accuracy,
        },
        "reference_sample": {
            "index": REFERENCE_SAMPLE_INDEX,
            "label": int(label),
            "prediction": int(prediction),
            "final_output": [
                int(value)
                for value in output_q[0].tolist()
            ],
        },
        "rtl_memory_layout": {
            "layer1_weight_shape": [784, 128],
            "layer1_weight_entries": 784 * 128,
            "layer2_weight_shape": [128, 10],
            "layer2_weight_entries": 128 * 10,
        },
    }

    with (
        OUTPUT_DIR / "quantization_config.json"
    ).open("w", encoding="utf-8") as file:
        json.dump(
            configuration,
            file,
            indent=2,
        )

    print()
    print("========================================")
    print("Exported files")
    print("========================================")

    for path in sorted(OUTPUT_DIR.iterdir()):
        print(path)

    print()
    print(
        f"Reference label      : {label}"
    )
    print(
        f"Reference prediction : {prediction}"
    )
    print(
        f"Reference output     : "
        f"{output_q[0].tolist()}"
    )


# ============================================================
# Main
# ============================================================

def main() -> None:
    torch.manual_seed(42)

    print("Loading model...")
    model, checkpoint = load_model()

    print("Loading MNIST test dataset...")
    test_dataset = load_test_dataset()

    print("Evaluating float model...")
    float_accuracy = evaluate_float_model(
        model,
        test_dataset,
    )

    print(
        f"Float model accuracy: "
        f"{float_accuracy * 100:.2f}%"
    )

    # --------------------------------------------------------
    # Weight quantization
    # --------------------------------------------------------

    w1_float = (
        model.fc1.weight
        .detach()
        .cpu()
    )

    w2_float = (
        model.fc2.weight
        .detach()
        .cpu()
    )

    w1_q, w1_scale = quantize_weight_symmetric(
        w1_float
    )

    w2_q, w2_scale = quantize_weight_symmetric(
        w2_float
    )

    print()
    print("Weight quantization:")
    print(
        f"fc1 shape={tuple(w1_q.shape)}, "
        f"scale={w1_scale:.10f}, "
        f"range=[{w1_q.min().item()}, "
        f"{w1_q.max().item()}]"
    )
    print(
        f"fc2 shape={tuple(w2_q.shape)}, "
        f"scale={w2_scale:.10f}, "
        f"range=[{w2_q.min().item()}, "
        f"{w2_q.max().item()}]"
    )

    # --------------------------------------------------------
    # Integer dataset
    # --------------------------------------------------------

    print()
    print("Converting test images to int8...")

    images_q, labels = collect_integer_test_data(
        test_dataset
    )

    print(
        f"Integer images shape: "
        f"{tuple(images_q.shape)}"
    )

    # --------------------------------------------------------
    # Shift search
    # --------------------------------------------------------

    shift1, shift2, _ = search_best_shifts(
        images_q=images_q,
        labels=labels,
        w1_q=w1_q,
        w2_q=w2_q,
    )

    # --------------------------------------------------------
    # Full test-set evaluation
    # --------------------------------------------------------

    print()
    print("Evaluating full integer test set...")

    integer_accuracy = evaluate_integer_accuracy(
        images_q=images_q,
        labels=labels,
        w1_q=w1_q,
        w2_q=w2_q,
        shift1=shift1,
        shift2=shift2,
    )

    print()
    print("========================================")
    print("Final quantization result")
    print("========================================")
    print(
        f"Float accuracy   : "
        f"{float_accuracy * 100:.2f}%"
    )
    print(
        f"Integer accuracy : "
        f"{integer_accuracy * 100:.2f}%"
    )
    print(f"Layer 1 shift    : {shift1}")
    print(f"Layer 2 shift    : {shift2}")
    print(f"Layer 1 ReLU     : enabled")
    print(f"Layer 2 ReLU     : disabled")

    # 저장된 checkpoint의 기록도 참고용으로 표시
    if "test_accuracy" in checkpoint:
        print(
            f"Checkpoint accuracy: "
            f"{checkpoint['test_accuracy'] * 100:.2f}%"
        )

    # --------------------------------------------------------
    # Export
    # --------------------------------------------------------

    export_quantized_files(
        dataset=test_dataset,
        w1_q=w1_q,
        w2_q=w2_q,
        w1_scale=w1_scale,
        w2_scale=w2_scale,
        shift1=shift1,
        shift2=shift2,
        float_accuracy=float_accuracy,
        integer_accuracy=integer_accuracy,
    )


if __name__ == "__main__":
    main()