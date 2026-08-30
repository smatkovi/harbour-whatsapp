/*
 * This file is a part of the Voice Call Manager Plugin project.
 *
 * Copyright (C) 2011-2012  Tom Swindell <t.swindell@rubyx.co.uk>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 *
 */
#ifndef COMMON_H
#define COMMON_H

#include <QLoggingCategory>

Q_DECLARE_LOGGING_CATEGORY(voicecall)

#define WARNING_T(message, ...) qCWarning(voicecall, "%s " message, Q_FUNC_INFO, ##__VA_ARGS__)
#define TRACE qCInfo(voicecall, "%s:%d %p", Q_FUNC_INFO, __LINE__, this);
#define DEBUG_T(message, ...) qCDebug(voicecall, "%s " message, Q_FUNC_INFO, ##__VA_ARGS__)

#endif // COMMON_H
