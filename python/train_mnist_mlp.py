from __future__ import annotations

import random
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


# ============================================================
# Configuration
# ============================================================

SEED = 42

BATCH_SIZE = 128
LEARNING_RATE = 1e-3
EPOCHS = 10

DATA_DIR = Path("./data")
OUTPUT_DIR = Path("./outputs")
MODEL_PATH = OUTPUT_DIR / "mnist_mlp_float.pth"

NUM_WORKERS = 2


# ============================================================
# Reproducibility
# ============================================================

def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)

    torch.manual_seed(seed)

    if torch.cuda.is_available():
        torch.cuda.manual_seed(seed)
        torch.cuda.manual_seed_all(seed)

    # 재현성 우선 설정
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False


# ============================================================
# Model
# ============================================================

class MNISTMLP(nn.Module):
    """
    MNIST MLP

    Input:
        [batch, 1, 28, 28]

    Network:
        784 -> 128 -> ReLU -> 10
    """

    def __init__(self, use_bias: bool = False) -> None:
        super().__init__()

        self.flatten = nn.Flatten()

        self.fc1 = nn.Linear(
            in_features=28 * 28,
            out_features=128,
            bias=use_bias,
        )

        self.relu = nn.ReLU()

        self.fc2 = nn.Linear(
            in_features=128,
            out_features=10,
            bias=use_bias,
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.flatten(x)
        x = self.fc1(x)
        x = self.relu(x)
        x = self.fc2(x)

        return x


# ============================================================
# Data
# ============================================================

def create_dataloaders() -> tuple[DataLoader, DataLoader]:
    """
    MNIST pixel values:
        uint8 0~255
        ToTensor 적용 후 float32 0.0~1.0

    우선 float 모델 학습 단계이므로 normalization은 넣지 않는다.
    이후 RTL 입력을 uint8/int8로 변환할 때 대응하기 쉽다.
    """

    transform = transforms.ToTensor()

    train_dataset = datasets.MNIST(
        root=DATA_DIR,
        train=True,
        transform=transform,
        download=True,
    )

    test_dataset = datasets.MNIST(
        root=DATA_DIR,
        train=False,
        transform=transform,
        download=True,
    )

    pin_memory = torch.cuda.is_available()

    train_loader = DataLoader(
        dataset=train_dataset,
        batch_size=BATCH_SIZE,
        shuffle=True,
        num_workers=NUM_WORKERS,
        pin_memory=pin_memory,
    )

    test_loader = DataLoader(
        dataset=test_dataset,
        batch_size=BATCH_SIZE,
        shuffle=False,
        num_workers=NUM_WORKERS,
        pin_memory=pin_memory,
    )

    return train_loader, test_loader


# ============================================================
# Train
# ============================================================

def train_one_epoch(
    model: nn.Module,
    loader: DataLoader,
    criterion: nn.Module,
    optimizer: torch.optim.Optimizer,
    device: torch.device,
) -> tuple[float, float]:

    model.train()

    total_loss = 0.0
    total_correct = 0
    total_samples = 0

    for images, labels in loader:
        images = images.to(device, non_blocking=True)
        labels = labels.to(device, non_blocking=True)

        optimizer.zero_grad(set_to_none=True)

        logits = model(images)
        loss = criterion(logits, labels)

        loss.backward()
        optimizer.step()

        batch_size = labels.size(0)

        total_loss += loss.item() * batch_size
        total_correct += (
            logits.argmax(dim=1) == labels
        ).sum().item()

        total_samples += batch_size

    average_loss = total_loss / total_samples
    accuracy = total_correct / total_samples

    return average_loss, accuracy


# ============================================================
# Evaluation
# ============================================================

@torch.inference_mode()
def evaluate(
    model: nn.Module,
    loader: DataLoader,
    criterion: nn.Module,
    device: torch.device,
) -> tuple[float, float]:

    model.eval()

    total_loss = 0.0
    total_correct = 0
    total_samples = 0

    for images, labels in loader:
        images = images.to(device, non_blocking=True)
        labels = labels.to(device, non_blocking=True)

        logits = model(images)
        loss = criterion(logits, labels)

        batch_size = labels.size(0)

        total_loss += loss.item() * batch_size
        total_correct += (
            logits.argmax(dim=1) == labels
        ).sum().item()

        total_samples += batch_size

    average_loss = total_loss / total_samples
    accuracy = total_correct / total_samples

    return average_loss, accuracy


# ============================================================
# Main
# ============================================================

def main() -> None:
    set_seed(SEED)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    device = torch.device(
        "cuda" if torch.cuda.is_available() else "cpu"
    )

    print(f"Device: {device}")

    train_loader, test_loader = create_dataloaders()

    # 현재 RTL은 bias 연산이 없으므로 bias=False로 맞춤
    model = MNISTMLP(use_bias=False).to(device)

    criterion = nn.CrossEntropyLoss()

    optimizer = torch.optim.Adam(
        model.parameters(),
        lr=LEARNING_RATE,
    )

    print()
    print(model)
    print()

    best_test_accuracy = 0.0

    for epoch in range(1, EPOCHS + 1):
        train_loss, train_accuracy = train_one_epoch(
            model=model,
            loader=train_loader,
            criterion=criterion,
            optimizer=optimizer,
            device=device,
        )

        test_loss, test_accuracy = evaluate(
            model=model,
            loader=test_loader,
            criterion=criterion,
            device=device,
        )

        print(
            f"Epoch [{epoch:02d}/{EPOCHS}] "
            f"train_loss={train_loss:.4f} "
            f"train_acc={train_accuracy * 100:.2f}% "
            f"test_loss={test_loss:.4f} "
            f"test_acc={test_accuracy * 100:.2f}%"
        )

        if test_accuracy > best_test_accuracy:
            best_test_accuracy = test_accuracy

            torch.save(
                {
                    "model_state_dict": model.state_dict(),
                    "architecture": {
                        "input_size": 784,
                        "hidden_size": 128,
                        "output_size": 10,
                        "bias": False,
                    },
                    "test_accuracy": test_accuracy,
                    "epoch": epoch,
                },
                MODEL_PATH,
            )

            print(
                f"  Best model saved: {MODEL_PATH}"
            )

    print()
    print(
        f"Best test accuracy: "
        f"{best_test_accuracy * 100:.2f}%"
    )

    print(f"Saved model: {MODEL_PATH}")


if __name__ == "__main__":
    main()