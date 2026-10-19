pluginManagement { repositories { mavenCentral(); maven("https://maven.aliyun.com/repository/google"); google(); gradlePluginPortal() } }
dependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { mavenCentral(); maven("https://maven.aliyun.com/repository/google"); google() } }
rootProject.name = "FeiyuAndroid"
include(":app")
