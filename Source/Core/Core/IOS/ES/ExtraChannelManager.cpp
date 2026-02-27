#include "Core/IOS/ES/ExtraChannelManager.h"

#include <filesystem>
#include <fstream>
#include <regex>

#include "Core/System.h"

#include "Common/Logging/Log.h"
#include "Common/StringUtil.h"
#include "Common/FileUtil.h"
#include "Common/CommonPaths.h"

// Helper function for case-insensitive string comparison
static bool iequals(const std::string& a, const std::string& b)
{
  return std::equal(a.begin(), a.end(), b.begin(), b.end(), [](char a, char b) {
    return std::tolower(static_cast<unsigned char>(a)) ==
           std::tolower(static_cast<unsigned char>(b));
  });
}

namespace IOS::HLE
{
using namespace std::filesystem;

std::unordered_map<u64, ExtraChannel> ExtraChannelManager::s_channels;
bool ExtraChannelManager::s_initialized = false;

// Default directory: read from environment variable for simplicity.
// Your Node script can write files to this path. Example:
//   export DOLPHIN_EXTRA_CHANNELS_DIR="/home/user/Dolphin/extra_channels"
static std::string GetDefaultDir()
{
  return File::GetUserPath(D_EXTRACHANNELS_IDX);
}

static void CreateDefaultDir()
{
  const std::string dir = GetDefaultDir();
  if (dir.empty())
  {
    INFO_LOG_FMT(IOS_ES, "ExtraChannelManager: no directory configured for extra channels");
    return;
  }

  File::CreateFullPath(dir);
  GetDefaultDir();
}

void ExtraChannelManager::Initialize()
{
  if (s_initialized)
    return;
  CreateDefaultDir();
  ExtraChannelManager::Reload();
  s_initialized = true;
}

void ExtraChannelManager::Reload()
{
  s_channels.clear();
  const std::string dir = GetDefaultDir();
  if (dir.empty())
  {
    INFO_LOG_FMT(IOS_ES, "ExtraChannelManager: no directory configured for extra channels");
    return;
  }
  LoadFromDirectory(dir);
}

void ExtraChannelManager::LoadFromDirectory(const std::string& host_dir)
{
  INFO_LOG_FMT(IOS_ES, "ExtraChannelManager: loading from '{}'", host_dir);
  try
  {
    for (const auto& ent : directory_iterator(host_dir))
    {
      if (!ent.is_regular_file())
        continue;

      // Expect files named like 00010010ABCDEF01.meta or 00010010ABCDEF01.json
      const std::string name = ent.path().filename().string();
      // Extract 16 hex chars at start (allow uppercase/lowercase)
      std::smatch m;
      static const std::regex r(R"(^([0-9A-Fa-f]{16}))");
      if (!std::regex_search(name, m, r))
        continue;

      const std::string idhex = m[1].str();
      u64 title = 0;
      try
      {
        title = std::stoull(idhex, nullptr, 16);
      }
      catch (...)
      {
        continue;
      }

      ExtraChannel ch;
      ch.title_id = title;

      // Try to read optional companion path file: <TITLEID>.path (contains ISO absolute path),
      // or parse small JSON-like line for "isoPath":"...".
      const path iso_path_file = ent.path().parent_path() / (idhex + ".path");
      if (exists(iso_path_file))
      {
        std::ifstream f(iso_path_file);
        std::string line;
        if (std::getline(f, line))
        {
          ch.iso_path = line;
        }
      }
      else
      {
        // Try to parse a tiny JSON file with "isoPath":"..." (naive, tolerate simple JSON)
        if (iequals(ent.path().extension().string(), ".json") ||
            iequals(ent.path().extension().string(), ".meta"))
        {
          std::ifstream f(ent.path());
          std::string all((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
          static const std::regex jre(R"("isoPath"\s*:\s*"([^"]+)");
          std::smatch jm;
          if (std::regex_search(all, jm, jre))
            ch.iso_path = jm[1].str();
          // banner path could be similarly parsed if desired
        }
      }

      s_channels.emplace(title, std::move(ch));
    }
    INFO_LOG_FMT(IOS_ES, "ExtraChannelManager: loaded {} channels", s_channels.size());
  }
  catch (const std::exception& e)
  {
    ERROR_LOG_FMT(IOS_ES, "ExtraChannelManager: failed to scan directory '{}': {}", host_dir,
                  e.what());
  }
}

std::vector<u64> ExtraChannelManager::GetExtraTitleIDs()
{
  std::vector<u64> out;
  out.reserve(s_channels.size());
  for (const auto& kv : s_channels)
    out.push_back(kv.first);
  return out;
}

bool ExtraChannelManager::IsExtraTitle(u64 title_id)
{
  return s_channels.contains(title_id);
}

ExtraChannel ExtraChannelManager::GetChannel(u64 title_id)
{
  ExtraChannel empty{};
  const auto it = s_channels.find(title_id);
  if (it == s_channels.end())
    return empty;
  return it->second;
}
}  // namespace IOS::HLE
