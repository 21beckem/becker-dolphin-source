// Copyright 2025 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "UdpBridge.h"

#include <array>
#include <optional>

#include <QtCore/QByteArray>
#include <QtCore/QJsonDocument>
#include <QtCore/QJsonObject>
#include <QtCore/QJsonParseError>
#include <QtCore/QString>
#include <QtCore/QTimer>

#include <SFML/Network/IpAddress.hpp>

#include <utility>

#include "Core/Config/MainSettings.h"

namespace
{
constexpr int SOCKET_POLL_INTERVAL_MS = 10;
constexpr int TITLE_POLL_INTERVAL_MS = 250;
}  // namespace

UdpBridge::UdpBridge(
  ChangeDiscCallback change_disc_callback,
  PowerOffCallback power_off_callback,
  GetTitleCallback get_title_callback,
  SetPauseCallback set_pause_callback,
  QObject* parent
)
    : QObject(parent),
      m_change_disc_callback(std::move(change_disc_callback)),
      m_power_off_callback(std::move(power_off_callback)),
      m_get_title_callback(std::move(get_title_callback)),
      m_set_pause_callback(std::move(set_pause_callback)),
      m_socket_poll_timer(new QTimer(this)),
      m_title_poll_timer(new QTimer(this))
{
  m_socket.setBlocking(false);
  const unsigned short udp_listen_port =
      static_cast<unsigned short>(Config::Get(Config::MAIN_UDP_BRIDGE_PORT));
  const sf::Socket::Status bind_status = m_socket.bind(udp_listen_port);
  if (bind_status != sf::Socket::Status::Done)
    return;

  connect(m_socket_poll_timer, &QTimer::timeout, this, [this] { OnSocketPoll(); });
  m_socket_poll_timer->start(SOCKET_POLL_INTERVAL_MS);

  connect(m_title_poll_timer, &QTimer::timeout, this, [this] { OnTitlePoll(); });
  m_title_poll_timer->start(TITLE_POLL_INTERVAL_MS);

  SendCurrentTitle();
}

void UdpBridge::OnSocketPoll()
{
  std::array<char, 8192> buffer{};
  std::size_t received_size = 0;
  std::optional<sf::IpAddress> sender;
  unsigned short sender_port = 0;

  while (m_socket.receive(buffer.data(), buffer.size(), received_size, sender, sender_port) ==
         sf::Socket::Status::Done)
  {
    if (sender.has_value())
    {
      m_remote_address = *sender;
      m_remote_port = sender_port;
    }

    HandleCommandDatagram(QByteArray(buffer.data(), static_cast<int>(received_size)));
  }
}

void UdpBridge::OnTitlePoll()
{
  const std::string title = m_get_title_callback();
  if (title == m_last_title)
    return;

  SendCurrentTitle();
}

void UdpBridge::HandleCommandDatagram(const QByteArray& datagram)
{
  QJsonParseError parse_error;
  const QJsonDocument doc = QJsonDocument::fromJson(datagram, &parse_error);
  if (parse_error.error != QJsonParseError::NoError || !doc.isObject())
  {
    SendError(QStringLiteral("invalid json"));
    return;
  }

  const QJsonObject obj = doc.object();
  const QString command = obj.value(QStringLiteral("cmd")).toString();
  if (command == QStringLiteral("ping"))
  {
    return SendResponse("ping", "true");
  }
  if (command == QStringLiteral("change_disc"))
  {
    const QString path = obj.value(QStringLiteral("path")).toString();
    if (path.isEmpty())
    {
      SendError(QStringLiteral("missing path"));
      return;
    }

    if (!m_change_disc_callback(path.toStdString()))
      SendError(QStringLiteral("invalid disc path"));
    return SendResponse("change_disc", "true");
  }

  if (command == QStringLiteral("power_off"))
  {
    m_power_off_callback();
    return SendResponse("power_off", "true");
  }

  if (command == QStringLiteral("get_title"))
  {
    SendCurrentTitle();
    return;
  }

  if (command == QStringLiteral("set_pause"))
  {
    const bool set_pause = obj.value(QStringLiteral("to")).toBool();
    if (!m_set_pause_callback(set_pause))
      SendError(QStringLiteral("failed to set pause"));
    return SendResponse("set_pause", "true");
  }

  SendError(QStringLiteral("unknown command"));
}

void UdpBridge::SendCurrentTitle()
{
  const std::string title = m_get_title_callback();
  m_last_title = title;

  SendResponse("get_title", title);
}

void UdpBridge::SendError(const QString& message)
{
  const QJsonObject payload{{QStringLiteral("event"), QStringLiteral("error")},
                            {QStringLiteral("message"), message}};

  SendPayload(payload);
}

void UdpBridge::SendResponse(const std::string& cmd, const std::string& response)
{
  const QJsonObject payload{{QStringLiteral("rsp"), QString::fromStdString(cmd)},
                            {QStringLiteral("message"), QString::fromStdString(response)}};

  SendPayload(payload);
}

void UdpBridge::SendPayload(const QJsonObject& payload)
{
  if (!m_remote_address.has_value() || m_remote_port == 0)
    return;

  const QByteArray bytes = QJsonDocument(payload).toJson(QJsonDocument::Compact);
  [[maybe_unused]] const sf::Socket::Status send_status =
      m_socket.send(bytes.constData(), static_cast<std::size_t>(bytes.size()), *m_remote_address,
                    m_remote_port);
}
