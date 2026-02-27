#pragma once

#include "Core/System.h"
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

namespace IOS::HLE
{
struct ExtraChannel
{
  u64 title_id;
  std::string iso_path;  // optional, may be empty
  std::string banner;    // optional path to a banner image
};

class ExtraChannelManager
{
public:
  // Called once on ES init (or lazily on first query).
  static void Initialize();

  // Reloads from disk (call after your node script runs if you want hot-reload).
  static void Reload();

  // Returns all extra title IDs (for GetTitles/GetTitleCount).
  static std::vector<u64> GetExtraTitleIDs();

  // True if the title is managed by extras.
  static bool IsExtraTitle(u64 title_id);

  // Get metadata (iso path / banner) for a title ID.
  static ExtraChannel GetChannel(u64 title_id);

private:
  static void LoadFromDirectory(const std::string& host_dir);
  static std::unordered_map<u64, ExtraChannel> s_channels;
  static bool s_initialized;
};

}  // namespace IOS::HLE
