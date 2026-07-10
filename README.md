# Libertix

A modern, user-friendly Windows application that simplifies the process of dual-booting Linux alongside Windows.

## Features

- 🎨 Modern, clean UI with Rose Pine theme
- 🔄 Intuitive disk space management
- 🌍 Multi-language support (English, French, Spanish, Japanese)
- 🔧 Smart partition handling
- 💾 State persistence between steps
- 🖼️ Visual disk space representation
- 📊 Real-time system requirements check

## Supported distribution

- Linux Mint 22.3 Cinnamon

## Requirements

- Windows 10 or Windows 11, in BIOS/MBR or UEFI/GPT mode
- .NET Framework 4.8
- At least 20GB of shrinkable free space on the Windows system disk
- Administrator privileges

BitLocker or Device Encryption must be fully decrypted before disk changes. Libertix performs this
check and requests decryption when required. The installer preserves the detected Windows recovery
partition and refuses unknown or ambiguous disk layouts.

## Development

1. Clone the repository:

```bash
git clone https://github.com/ekimiateam/libertix.git
```

2. Open the solution in Visual Studio 2022

3. Install the .NET Framework 4.8 SDK/targeting pack and restore NuGet packages

4. Build and run the project

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the GNU General Public License 3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Rose Pine](https://rosepinetheme.com/) for the color scheme
- [WPF](https://github.com/dotnet/wpf) for the UI framework
