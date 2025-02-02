// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import { IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AddressSet, AddressArray } from "@1inch/solidity-utils/contracts/libraries/AddressSet.sol";

import { IERC20Plugins } from "./interfaces/IERC20Plugins.sol";
import { IPlugin } from "./interfaces/IPlugin.sol";
import { ReentrancyGuardExt, ReentrancyGuardLib } from "./libs/ReentrancyGuard.sol";

/**
 * @title ERC20Plugins
 * @dev A base implementation of token contract to hold and manage plugins of an ERC20 token with a limited number of plugins per account.
 * Each plugin is a contract that implements IPlugin interface (and/or derived from plugin).
 */
abstract contract ERC20Plugins is ERC20, IERC20Plugins, ReentrancyGuardExt {
    using AddressSet for AddressSet.Data;
    using AddressArray for AddressArray.Data;
    using ReentrancyGuardLib for ReentrancyGuardLib.Data;

    error PluginAlreadyAdded();
    error PluginNotFound();
    error InvalidPluginAddress();
    error InvalidTokenInPlugin();
    error PluginsLimitReachedForAccount();
    error ZeroPluginsLimit();

    /// @dev Limit of plugins per account
    uint256 public immutable pluginsCountLimit;
    /// @dev Gas limit for a single plugin call
    uint256 public immutable pluginsCallGasLimit;

    ReentrancyGuardLib.Data private _guard;
    mapping(address => AddressSet.Data) private _plugins;

    /**
     * @dev Constructor that sets the limit of plugins per account and the gas limit for a plugin call.
     * @param pluginsLimit_ The limit of plugins per account.
     * @param pluginCallGasLimit_ The gas limit for a plugin call. Intended to prevent gas bomb attacks
     */
    constructor(uint256 pluginsLimit_, uint256 pluginCallGasLimit_) {
        if (pluginsLimit_ == 0) revert ZeroPluginsLimit();
        pluginsCountLimit = pluginsLimit_;
        pluginsCallGasLimit = pluginCallGasLimit_;
        _guard.init();
    }

    /**
     * @dev Returns whether an account has a specific plugin.
     * @param account The address of the account.
     * @param plugin The address of the plugin.
     * @return bool A boolean indicating whether the account has the specified plugin.
     */
    function hasPlugin(address account, address plugin) public view virtual returns(bool) {
        return _plugins[account].contains(plugin);
    }

    /**
     * @dev Returns the number of plugins registered for an account.
     * @param account The address of the account.
     * @return uint256 A number of plugins registered for the account.
     */
    function pluginsCount(address account) public view virtual returns(uint256) {
        return _plugins[account].length();
    }

    /**
     * @dev Returns the address of a plugin at a specified index for a given account .
     * @param account The address of the account.
     * @param index The index of the plugin to retrieve.
     * @return plugin The address of the plugin.
     */
    function pluginAt(address account, uint256 index) public view virtual returns(address) {
        return _plugins[account].at(index);
    }

    /**
     * @dev Returns an array of all plugins owned by a given account.
     * @param account The address of the account to query.
     * @return plugins An array of plugin addresses.
     */
    function plugins(address account) public view virtual returns(address[] memory) {
        return _plugins[account].items.get();
    }


    /**
     * @dev Returns the balance of a given account.
     * @param account The address of the account.
     * @return balance The account balance.
     */
    function balanceOf(address account) public nonReentrantView(_guard) view override(IERC20, ERC20) virtual returns(uint256) {
        return super.balanceOf(account);
    }

    /**
     * @dev Returns the balance of a given account if a specified plugin is added or zero.
     * @param plugin The address of the plugin to query.
     * @param account The address of the account to query.
     * @return balance The account balance if the specified plugin is added and zero otherwise.
     */
    function pluginBalanceOf(address plugin, address account) public nonReentrantView(_guard) view virtual returns(uint256) {
        if (hasPlugin(account, plugin)) {
            return super.balanceOf(account);
        }
        return 0;
    }

    /**
     * @dev Adds a new plugin for the calling account.
     * @param plugin The address of the plugin to add.
     */
    function addPlugin(address plugin) public virtual {
        _addPlugin(msg.sender, plugin);
    }

    /**
     * @dev Removes a plugin for the calling account.
     * @param plugin The address of the plugin to remove.
     */
    function removePlugin(address plugin) public virtual {
        _removePlugin(msg.sender, plugin);
    }

    /**
     * @dev Removes all plugins for the calling account.
     */
    function removeAllPlugins() public virtual {
        _removeAllPlugins(msg.sender);
    }

    function _addPlugin(address account, address plugin) internal virtual {
        if (plugin == address(0)) revert InvalidPluginAddress();
        if (IPlugin(plugin).token() != IERC20Plugins(address(this))) revert InvalidTokenInPlugin();
        if (!_plugins[account].add(plugin)) revert PluginAlreadyAdded();
        if (_plugins[account].length() > pluginsCountLimit) revert PluginsLimitReachedForAccount();

        emit PluginAdded(account, plugin);
        uint256 balance = balanceOf(account);
        if (balance > 0) {
            _updateBalances(plugin, address(0), account, balance);
        }
    }

    function _removePlugin(address account, address plugin) internal virtual {
        if (!_plugins[account].remove(plugin)) revert PluginNotFound();

        emit PluginRemoved(account, plugin);
        uint256 balance = balanceOf(account);
        if (balance > 0) {
            _updateBalances(plugin, account, address(0), balance);
        }
    }

    function _removeAllPlugins(address account) internal virtual {
        address[] memory items = _plugins[account].items.get();
        uint256 balance = balanceOf(account);
        unchecked {
            for (uint256 i = items.length; i > 0; i--) {
                _plugins[account].remove(items[i - 1]);
                emit PluginRemoved(account, items[i - 1]);
                if (balance > 0) {
                    _updateBalances(items[i - 1], account, address(0), balance);
                }
            }
        }
    }

    /// @notice Assembly implementation of the gas limited call to avoid return gas bomb,
    // moreover call to a destructed plugin would also revert even inside try-catch block in Solidity 0.8.17
    /// @dev try IPlugin(plugin).updateBalances{gas: _PLUGIN_CALL_GAS_LIMIT}(from, to, amount) {} catch {}
    function _updateBalances(address plugin, address from, address to, uint256 amount) private {
        bytes4 selector = IPlugin.updateBalances.selector;
        uint256 gasLimit = pluginsCallGasLimit;
        assembly ("memory-safe") { // solhint-disable-line no-inline-assembly
            let ptr := mload(0x40)
            mstore(ptr, selector)
            mstore(add(ptr, 0x04), from)
            mstore(add(ptr, 0x24), to)
            mstore(add(ptr, 0x44), amount)

            let gasLeft := gas()
            if iszero(call(gasLimit, plugin, 0, ptr, 0x64, 0, 0)) {
                if lt(div(mul(gasLeft, 63), 64), gasLimit) {
                    returndatacopy(ptr, 0, returndatasize())
                    revert(ptr, returndatasize())
                }
            }
        }
    }

    // ERC20 Overrides

    function _afterTokenTransfer(address from, address to, uint256 amount) internal nonReentrant(_guard) override virtual {
        super._afterTokenTransfer(from, to, amount);

        unchecked {
            if (amount > 0 && from != to) {
                address[] memory a = _plugins[from].items.get();
                address[] memory b = _plugins[to].items.get();
                uint256 aLength = a.length;
                uint256 bLength = b.length;

                for (uint256 i = 0; i < aLength; i++) {
                    address plugin = a[i];

                    uint256 j;
                    for (j = 0; j < bLength; j++) {
                        if (plugin == b[j]) {
                            // Both parties are participating of the same plugin
                            _updateBalances(plugin, from, to, amount);
                            b[j] = address(0);
                            break;
                        }
                    }

                    if (j == bLength) {
                        // Sender is participating in a plugin, but receiver is not
                        _updateBalances(plugin, from, address(0), amount);
                    }
                }

                for (uint256 j = 0; j < bLength; j++) {
                    address plugin = b[j];
                    if (plugin != address(0)) {
                        // Receiver is participating in a plugin, but sender is not
                        _updateBalances(plugin, address(0), to, amount);
                    }
                }
            }
        }
    }
}
