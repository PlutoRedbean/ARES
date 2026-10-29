package npc

import mill._
import scalalib._

val chiselVersion = "7.0.0-M2"
val defaultScalaVersion = "2.13.14"
val chiselPluginVersion = "7.0.0-M2"

// This build.sc lives in rtl/pipeline/gen; the Milestone-0 source tree is
// rtl/pipeline (one directory up).  MILL_WORKSPACE_ROOT is the gen directory.
val pwd = os.Path(sys.env("MILL_WORKSPACE_ROOT")) / os.up

object Mundus extends ScalaModule {
  override def millSourcePath = pwd
  override def scalaVersion = defaultScalaVersion

  override def sources = Task.Sources(
    millSourcePath / "core" / "scsrc",
    millSourcePath / "gen" / "configs" / "scsrc",
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
}
