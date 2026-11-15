# 技术设计文档: Immersive Controller MVP

## 🛠 构建策略：精准打击 (Precision Vibe-Coding)

鉴于您要求 **<20ms 延迟** 和 **1周交付**，我们不能使用常规的“试错法”。我们将采用 **“核心分离”** 策略：
1.  **PC 端**：使用多进程架构，将计算密集型任务 (CV) 与 I/O 密集型任务 (网络接收) 物理隔离。
2.  **Android 端**：抛弃花哨的框架，使用最底层的 Java UDP Socket 以避免垃圾回收 (GC) 卡顿。
3.  **AI 协作模式**：您不仅是 Prompt 输入者，更是**系统架构师**。您将使用我提供的“超级 Prompt”来生成高质量代码。

---

## 🏗 系统架构 (System Architecture)

这是整个系统的蓝图。请务必让 Gemini 理解这个结构。

```mermaid
graph TD
    subgraph "Android Phone (Sender)"
        A[Touch Screen/IMU] -->|Raw Data| B(Java UDP Sender)
        B -->|OSC Packets (60Hz)| C{Wi-Fi Network}
    end

    subgraph "Windows PC (Receiver & Processor)"
        C -->|UDP Port 9000| D[Process 1: Network Listener]
        E[Webcam] -->|Frames| F[Process 2: CV Engine]
        
        D -->|Write Shared Memory| G[Shared State Block]
        F -->|Write Shared Memory| G
        
        G -->|Read (Low Latency)| H[Process 3: Input Logic]
        H -->|Kalman Filter| H
        H -->|ViGEmBus| I[Virtual Xbox 360]
    end
    
    I --> J[Dark Souls 3]
