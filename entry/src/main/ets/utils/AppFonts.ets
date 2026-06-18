/*
 * Copyright (c) 2023 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Centralized font family constants.
 *
 * OTP/TOTP codes only ever contain ASCII characters (digits 0-9, and for the
 * Steam variant the ASCII base-26 alphabet), so the generic 'monospace'
 * family renders identically across all locales. Keeping it as a named
 * constant gives a single source of truth for all code-display sites.
 */
export class AppFonts {
  static readonly CODE_FONT: string = 'monospace';
}
