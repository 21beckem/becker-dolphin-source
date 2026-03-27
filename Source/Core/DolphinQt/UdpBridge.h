// Copyright 2025 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <QObject>

#include <functional>
#include <optional>
#include <string>

#include <SFML/Network/UdpSocket.hpp>

class QByteArray;
class QJsonObject;
class QString;
class QTimer;

class UdpBridge final : public QObject
{
public:
  using ChangeDiscCallback = std::function<bool(const std::string& path)>;
  using PowerOffCallback = std::function<void()>;
  using GetTitleCallback = std::function<std::string()>;

  UdpBridge(ChangeDiscCallback change_disc_callback, PowerOffCallback power_off_callback,
            GetTitleCallback get_title_callback, QObject* parent = nullptr);

private:
  void OnSocketPoll();
  void OnTitlePoll();
  void HandleCommandDatagram(const QByteArray& datagram);

  void SendCurrentTitle();
  void SendError(const QString& message);
  void SendResponse(const std::string& cmd, const std::string& response);
  void SendPayload(const QJsonObject& payload);

  ChangeDiscCallback m_change_disc_callback;
  PowerOffCallback m_power_off_callback;
  GetTitleCallback m_get_title_callback;

  sf::UdpSocket m_socket;
  QTimer* m_socket_poll_timer;
  QTimer* m_title_poll_timer;
  std::optional<sf::IpAddress> m_remote_address;
  unsigned short m_remote_port = 0;
  std::string m_last_title;
};
