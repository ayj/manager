load("@io_bazel_rules_go//go:def.bzl", "go_binary", "go_library")

go_library(
    name = "go_default_library",
    srcs = ["benchmark.go"],
    deps = [
        "@com_github_golang_glog//:go_default_library",
        "@com_github_golang_sync//errgroup:go_default_library",
        "@com_github_montanaflynn_stats//:go_default_library",
    ],
)

go_binary(
    name = "benchmark",
    library = ":go_default_library",
    visibility = ["//visibility:public"],
)
