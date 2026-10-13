import chisel3._
import chisel3.util._
import chiseltest._
import chiseltest.formal._
import org.scalatest.flatspec.AnyFlatSpec

class Sub extends Module {
  val io = IO(new Bundle {
    val a = Input(UInt(4.W))
    val b = Input(UInt(4.W))
    val c = Output(UInt(4.W))
  })
  // 插入的错误
  // io.c := io.a + ~io.b + Mux(io.a === 2.U, 0.U, 1.U)
  // 正确实现
  io.c := io.a + ~io.b + 1.U

	// 在模块内部设置断言（可访问内部变量和）
  // val ref = io.a - io.b
  // assert(io.c === ref)
}

class SubFormalTop extends Module {
	// 外部模块只可访问被测模块的输入输出变量
  val io = IO(new Bundle {
    val a = Input(UInt(4.W))
    val b = Input(UInt(4.W))
  })

  val dut = Module(new Sub())
  dut.io.a := io.a
  dut.io.b := io.b
  
  val refOutput = Wire(UInt(4.W))
  refOutput := io.a - io.b
  
  // 使用 cf-interpolator
  assert(dut.io.c === refOutput, 
    cf"DUT output ${dut.io.c} should equal reference ${refOutput} when a=${io.a}, b=${io.b}")
  
  when(io.a >= io.b) {
    assert(dut.io.c === io.a - io.b, 
      cf"When a >= b, output should be a-b, got ${dut.io.c} for a=${io.a}, b=${io.b}")
  }
  
  assert(dut.io.c === io.a + (~io.b) + 1.U, 
    cf"Two's complement subtraction formula should hold")
}


// 形式化验证测试类
class SubFormalSpec extends AnyFlatSpec with ChiselScalatestTester with Formal {
  "Sub" should "pass formal verification" in {
    verify(new SubFormalTop(), Seq(
      BoundedCheck(1),
      BtormcEngineAnnotation
    ))
  }
}
