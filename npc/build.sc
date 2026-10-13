package npc

import mill._
import scalalib._
import mill.scalalib.TestModule

// 主项目
val chiselVersion = "7.0.0-M2"
val defaultScalaVersion = "2.13.14"
val chiselPluginVersion = "7.0.0-M2"

// 验证模块
val chisel3Version = "3.6.1"
val chiseltestVersion = "0.6.1"
val scalaTestVersion = "3.2.15"

val pwd = os.Path(sys.env("MILL_WORKSPACE_ROOT"))


object Mundus extends ScalaModule {
  override def millSourcePath = pwd
  override def scalaVersion = defaultScalaVersion

  override def sources = Task.Sources(
    millSourcePath / "scsrc",
    millSourcePath / "configs/build/scsrc",
  )

  override def ivyDeps = Agg(
    ivy"org.chipsalliance::chisel:${chiselVersion}"
  )

  override def scalacPluginIvyDeps = Agg(
    ivy"org.chipsalliance:::chisel-plugin:${chiselPluginVersion}"
  )

  override def scalacOptions = super.scalacOptions() ++ Agg(
    "-language:reflectiveCalls",
    "-Ymacro-annotations",
    "-Ytasty-reader"
  )

	// 测试模块：独立使用 Chisel3 做形式化验证
  object test extends ScalaModule with TestModule.ScalaTest {
    override def scalaVersion = "2.12.18"  // Chisel3 只支持 2.12
    override def millSourcePath = pwd

    override def sources = Task.Sources(
      millSourcePath / "FormalTest",
      millSourcePath / "configs/build/scsrc",
      millSourcePath / "scsrc/Config.scala",
    )

    override def ivyDeps = Agg(
      ivy"edu.berkeley.cs::chisel3:${chisel3Version}",
      ivy"edu.berkeley.cs::chiseltest:${chiseltestVersion}",
      ivy"org.scalatest::scalatest:${scalaTestVersion}"
    )

    override def scalacPluginIvyDeps = Agg(
      ivy"edu.berkeley.cs:::chisel3-plugin:${chisel3Version}"
    )

    override def scalacOptions = super.scalacOptions() ++ Agg(
      "-language:reflectiveCalls"
    )
  }
}
