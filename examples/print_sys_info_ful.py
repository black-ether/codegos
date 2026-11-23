import platform
import torch
import psutil
import sys
import os
import subprocess
import datetime
import pkg_resources

def print_extended_info():
    print("=== System Information ===")
    print(f"Platform: {platform.system()} {platform.release()} ({platform.machine()})")
    
    print("\n=== GPU Details ===")
    if torch.cuda.is_available():
        print(f"Number of GPUs: {torch.cuda.device_count()}")
        for i in range(torch.cuda.device_count()):
            print(f"GPU {i}: {torch.cuda.get_device_name(i)}")
        print(f"CUDA Version: {torch.version.cuda}")
        print(f"cuDNN Version: {torch.backends.cudnn.version()}")
        
        # GPU temperature
        try:
            temp = subprocess.check_output(['nvidia-smi', '--query-gpu=temperature.gpu', '--format=csv,noheader']).decode().strip()
            print(f"GPU Temperature: {temp}°C")
        except:
            print("GPU Temperature: Not available")
    else:
        print("CUDA not available")
    
    print("\n=== CPU Details ===")
    print(f"CPU Model: {platform.processor()}")
    print(f"CPU Cores: {psutil.cpu_count(logical=False)} physical, {psutil.cpu_count(logical=True)} logical")
    print(f"CPU Usage: {psutil.cpu_percent()}%")
    
    print("\n=== Memory ===")
    print(f"Total RAM: {psutil.virtual_memory().total // 1024**2} MB")
    if torch.cuda.is_available():
        print(f"Total VRAM: {torch.cuda.get_device_properties(0).total_memory // 1024**2} MB")
    
    print("\n=== Storage ===")
    project_path = os.getcwd()
    disk = psutil.disk_usage(project_path)
    print(f"Project Path: {project_path}")
    print(f"Disk Space: Total {disk.total // 1024**3} GB, Free {disk.free // 1024**3} GB")
    
    print("\n=== Software Versions ===")
    print(f"Python Version: {sys.version}")
    print(f"PyTorch Version: {torch.__version__}")
    print(f"psutil Version: {psutil.__version__}")
    
    print("\n=== Environment ===")
    venv_active = hasattr(sys, 'real_prefix') or (hasattr(sys, 'base_prefix') and sys.base_prefix != sys.prefix)
    conda_active = 'CONDA_PREFIX' in os.environ

    print(f"Virtual Environment: {'Yes' if venv_active or conda_active else 'No'}")    
    print(f"Python Executable: {sys.executable}")
    
    print("\n=== Network ===")
    print(f"Hostname: {platform.node()}")
    for interface, addrs in psutil.net_if_addrs().items():
        print(f"  {interface}: {addrs[0].address}")
    
    print("\n=== CUDA Configuration ===")
    print(f"cuDNN Enabled: {torch.backends.cudnn.enabled}")
    print(f"cuDNN Benchmark: {torch.backends.cudnn.benchmark}")
    print(f"cuDNN Deterministic: {torch.backends.cudnn.deterministic}")

if __name__ == "__main__":
    print_extended_info()